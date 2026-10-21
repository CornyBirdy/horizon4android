# Horizon on Android

Horizon runs natively on Android (ARM64, Vulkan), aimed at the Samsung Galaxy Z Fold 5: the same
game loop as the desktop client, with touch controls, Bluetooth keyboard and mouse support, and
lighter defaults for a phone.

> **Read this first: it has not been compiled for Android or run on a device.**
> This port was written in a sandbox that could not reach the Rust Android target, the NDK, crates.io or
> a phone. The Rust, Java and scripts were checked by reading, by `rustfmt`, and by compiling and testing
> the pieces that depend on nothing but `std` (the touch controls, the platform event queue, the mods stub,
> the Java sources' syntax). Expect to meet a few compile errors on the first `build-apk` and some runtime
> surprises on the phone. [TESTING.md](TESTING.md) is a checklist ordered from "the app launches" to
> "walk around a world", so you can report exactly which step fails. The desktop builds do not change
> (see [What changed in shared code](#what-changed-in-shared-code)).

Horizon contains no Minecraft files. They are prepared on a computer from your own Minecraft Java
Edition with `horizon-prepare`, and copied to the phone; see [Resources](#resources).

## Contents

- [How it is built](#how-it-is-built) and why
- [Build](#build)
- [Device setup](#device-setup)
- [Resources](#resources)
- [Running](#running)
- [Controls](#controls)
- [Defaults for a phone](#defaults-for-a-phone)
- [Lifecycle: background, rotate, fold](#lifecycle-background-rotate-fold)
- [Logs and debugging](#logs-and-debugging)
- [Known issues and limits](#known-issues-and-limits)
- [What changed in shared code](#what-changed-in-shared-code)
- [Decisions](#decisions)
- [What next](#what-next)

## How it is built

```
android/
  build-apk.sh / build-apk.ps1     the one build script -> dist/horizon-android-debug.apk
  push-resources.sh / .ps1         horizon-prepare -> adb push
  native/                          crate horizon-android (cdylib): android_main, logcat, JNI entry points
  app/AndroidManifest.xml          two activities
  app/java/dev/horizon/android/
    LauncherActivity.java          the front door and the readable error screen
    HorizonActivity.java           NativeActivity subclass: mouse, pointer capture, thermal, back = Escape
crates/horizon-client/src/
  game.rs  game/*.rs               the desktop game loop, unchanged in behaviour; part of the library on Android
  game/touch.rs                    touch controls and the Android mouse in the game loop
  game/surface.rs                  the window's surface coming and going
  touch.rs                         touch controls as pure logic (fingers in, actions out; unit tests)
  platform.rs                      events from the Java side, requests to it, thermal state
  mobile.rs                        first-run phone defaults
  winit_host.rs                    the event loop per platform
```

The game itself is the desktop client's: `game.rs` and its modules are compiled into the `horizon-client`
library on Android (they are the binary's private modules on the desktop), and `horizon_client::run_game()`
is the loop `main` runs. The `horizon-android` library is the thin layer around it: it sets up the game
folder, logging and crash reports and starts that loop on the thread `android-activity` gives it.

The app has two activities in two processes:

- **LauncherActivity** (main process) is what the icon opens. It says whether the resources are on the phone
  and where to put them, starts the game, and shows why the last run ended badly: the message the game left
  in `last-error.txt`, or, if the process died without one (a crash in the graphics driver), the end of the log.
- **HorizonActivity** (the `:game` process) is Android's `NativeActivity` with a few additions. The game runs
  in its own process because it keeps process-wide state and runs once per process: when the activity is
  destroyed it kills that process, and the launcher stays up with the result on screen.

## Build

Build on the computer you used for the desktop game; the APK is built for `arm64-v8a` only.

### Install once

1. **Rust** with the Android target and `cargo-ndk`:
   ```sh
   rustup target add aarch64-linux-android
   cargo install cargo-ndk
   ```
2. **Android SDK and NDK.** Install Android Studio (or just the command-line tools) and, in SDK Manager,
   these packages: *Android SDK Platform 34*, *Android SDK Build-Tools 34.0.0*, *NDK (Side by side)* r26 or newer,
   and *Platform-Tools* (for `adb`). Then set the environment variables (Windows: *System Properties, Environment
   Variables*; restart the terminal):
   - `ANDROID_HOME` = the SDK folder (Windows default `%LOCALAPPDATA%\Android\Sdk`)
   - `ANDROID_NDK_HOME` = a folder inside `ANDROID_HOME\ndk\` (optional: `cargo-ndk` finds the newest one)
   - put `%ANDROID_HOME%\platform-tools` on the `PATH`
3. **A JDK 11 or newer** for `javac`, `jar` and `keytool`. The JDK 25 the desktop game needs for preparing
   works for these; Android Studio's bundled JDK (`jbr`) does too. No Gradle is involved.

### Build the APK

Windows (PowerShell):

```powershell
android\build-apk.ps1            # -> dist\horizon-android-debug.apk
android\build-apk.ps1 -Install   # and adb install -r it
```

Linux, macOS (or WSL with a Linux SDK):

```sh
android/build-apk.sh             # -> dist/horizon-android-debug.apk
android/build-apk.sh --install
```

| Option | Meaning |
| --- | --- |
| `--release` / `-Release` | Full optimisation with thin LTO. The default is the `fast` profile: optimised, no LTO, many codegen units, incremental. Slower to build, a little faster to run. |
| `--no-audio` / `-NoAudio` | Leave sound (`cpal`) out, if it fails to build or run. |
| `--mods` / `-Mods` | Build the WebAssembly mod runtime (`wasmtime`) in. |
| `--skip-native` / `-SkipNative` | Reuse the last native library (only Java or resources changed). |
| `--install` / `-Install` | `adb install -r` the APK on the connected phone. |

The first build compiles the whole game for ARM64 and takes a while. The script:

1. seeds `android/native/Cargo.lock` from the desktop `Cargo.lock` (so every dependency has the version the desktop
   game is tested with) and runs `cargo ndk -t arm64-v8a -P 30 build` in `android/native`;
2. packages with the SDK's own tools: `aapt2` (manifest and icon), `javac` and `d8` (the two Java classes),
   `jar`/`zipalign` (the APK) and `apksigner`;
3. signs it with the standard debug key (`~/.android/debug.keystore`, created if missing), so a rebuilt APK
   installs over the last one and keeps the game folder.

Mods with code (WebAssembly, `wasmtime`) are left out of the Android build by default (a smaller, quicker build, and one dependency
less to go wrong); `--mods` builds them in. Content-only mods work either way.

## Device setup

1. **Developer options:** *Settings, About phone, Software information*, tap *Build number* seven times.
2. *Settings, Developer options*: turn on **USB debugging**.
3. Connect the phone to the computer with a cable, accept the *Allow USB debugging* prompt on the phone
   (tick *Always allow*), and check `adb devices` lists it as `device`.
4. `adb install -r dist/horizon-android-debug.apk` (or `-Install`). Play Protect may ask about an app from an
   unknown developer: choose *Install anyway*.

## Resources

The game needs the files `horizon-prepare` builds from **your own** Minecraft Java Edition 26.3 install (the same
step as on the desktop, see [Build from source](README.md#build-from-source) and
[the native client guide](docs/native-client.md)). Nothing is downloaded and nothing of Minecraft's is stored in this repository.

On the computer:

```powershell
# Windows. Needs: Minecraft 26.3 played once from the official launcher, the 26.3 server jar you downloaded,
# a JDK 25 (horizon-prepare's), and the phone connected over adb.
android\push-resources.ps1 -Prepare -ServerJar C:\Users\you\Downloads\server.jar
```

```sh
# Linux, macOS
android/push-resources.sh --prepare --server-jar ~/Downloads/server.jar
```

That runs `horizon-prepare --prepare`, then `horizon-prepare sounds` (optional, about 380 MB; `-NoSounds` /
`--no-sounds` skips it), then copies the prepared folder to the phone. If you already have prepared resources
(for example from the Horizon launcher), skip the preparing and name the folder:

```sh
android/push-resources.sh --resources ~/.local/share/horizon/<version>/.local/horizon-client/26.3
```

By hand, the whole thing is one command:

```sh
adb shell mkdir -p /sdcard/Android/data/dev.horizon.android/files/resources
adb push <prepared folder>/. /sdcard/Android/data/dev.horizon.android/files/resources/
```

The folder you push must be the one that holds `horizon-resources.json` (the `.local/horizon-client/26.3` of a
prepared checkout). Copying many small files with `adb push` is slow (minutes); on Linux and macOS
`push-resources.sh --tar` streams a tar archive instead, which is much faster. The launcher screen shows a green
"Resources found" line once `resources/horizon-resources.json` is there. Without it the game stops at start with
a message saying what to copy where (on the launcher screen, and in `last-error.txt`).

The game folder is `/sdcard/Android/data/dev.horizon.android/files/` (the app's external files directory):

| Path | What |
| --- | --- |
| `resources/` | the prepared resources (you copy these) |
| `saves/` | worlds (vanilla Anvil format; `adb pull` one to open it on the desktop) |
| `options.txt`, `horizon-graphics.txt`, `horizon-controller.txt`, ... | settings, as on the desktop |
| `logs/latest.log`, `crash-reports/` | the log of the run and crash reports |
| `last-error.txt`, `running.marker` | what the launcher screen reads |
| `horizon-args.txt` | optional command-line arguments, one or more per line (see below) |
| `horizon-touch.txt` | optional touch layout tuning (see below) |

On Android 11 and newer other apps and the Files app cannot open `Android/data`, but `adb push` and `adb pull` can.

## Running

Open **Horizon** on the phone: the launcher screen shows the state. **Start Horizon** opens the game full screen. The first start
writes the phone defaults to `options.txt` and `horizon-graphics.txt` (only where they do not exist) and shows the
loading screen, then the title menu.

Command-line arguments (the desktop options `--world`, `--creative`, `--render-distance N`, `--seed`, `--server HOST`...) go in
`horizon-args.txt` in the game folder, whitespace separated, `#` starting a comment line:

```
# straight into a creative world
--world Test --creative
```

Quit from the title screen by leaving the app (Home, then swipe it away), or use *Save and Quit to Title* in the pause menu and
close the app. Closing the activity saves the world first.

## Controls

### Touch (in the world)

| Control | Does |
| --- | --- |
| Left thumb, anywhere on the left 42% (below the top quarter) | **Floating stick**: the base appears where the thumb lands. Push the stick all the way forward to sprint. |
| Drag anywhere else | **Look** (the Mouse Sensitivity option scales it) |
| **Break** (bottom right) | Attack and mine; *hold to keep breaking* |
| **Place** | Place a block / use the item; hold to keep using (eating, bows) |
| **Jump** | Jump; double tap in creative to fly, as with Space |
| **Sneak** | Toggles sneaking (it lights while on) |
| **Menu** (top left) | Pause menu |
| **Chat** | Opens chat with the on-screen keyboard |
| **Inv** / **Drop** (top right) | Inventory / throw the item in hand |
| Tap a **hotbar** slot | Select it; **swipe** along the hotbar to step the selection |

### Touch (in menus, inventories, the title screen)

The first finger is the mouse (a tap is a click, a drag drags items and sliders). A toolbar runs down the left edge:

| Button | Does |
| --- | --- |
| **Back** | Escape (close the screen, go back a menu) |
| **Shift** | Toggle: holds Shift for your taps (quick-move stacks in inventories) |
| **Right** | Makes your *next* tap a right click (split a stack, place one item) |
| **Up** / **Down** | Scroll lists (hold to repeat) |
| **Keys** | Opens or closes the on-screen keyboard; it types into chat, signs, books, search boxes, world names and the options' fields |

The system **back gesture** (or button) is Escape too. Chat opens the on-screen keyboard by itself.

### Bluetooth keyboard and mouse

A keyboard works as on the desktop (the default key bindings; text goes straight into fields). A **mouse** works as on the
desktop: moving the pointer, clicking and the wheel in menus, and in the world the app captures the pointer for **mouse look**
(Android's pointer capture), left click breaks, right click places. Pressing Escape frees the pointer for the pause menu.
The touch controls stay usable beside them.

### Tuning the touch layout

`horizon-touch.txt` in the game folder overrides the layout (one `key:value` per line, values are clamped to sane ranges;
sizes in dp):

```
buttonSize:0.20     # a button's edge as a fraction of the screen's shorter side (default 0.16, kept between buttonMin and buttonMax)
buttonMin:48
buttonMax:72
margin:20
gap:10
stickRadius:64
stickZone:0.42      # how much of the screen's left a thumb can start the stick in
deadzone:0.14
sprintPush:0.97
lookGain:1.6        # look speed of a drag
```

The defaults are in `Layout::default()` in `crates/horizon-client/src/touch.rs`, where the arrangement (`arrange`) is plain code and has
unit tests for the Fold 5's cover screen (held sideways and upright) and unfolded screen: nothing overlaps, nothing leaves the
screen, nothing covers the hotbar, and buttons stay between 48 and 72 dp.

## Defaults for a phone

On the first start (only where the file does not exist), `mobile.rs` writes lighter settings than the desktop's; anything you
change in the options is yours from then on.

| Setting | Desktop | Android | Why |
| --- | --- | --- | --- |
| Render distance | 12 | **6** | mesh count and GPU memory grow with its square |
| Simulation distance | 12 | **5** (vanilla's minimum) | mob and block ticking |
| Max FPS | 120 | **60** | heat and battery |
| Mipmap levels | 4 | **2** | texture memory and bandwidth |
| Biome blend | 2 | **1** | meshing time |
| Particles | all | **decreased** | fill rate |
| Entity distance | 100% | **75%** | draw calls |
| Entity shadows | on | **off** | extra passes |
| Clouds | fancy | **fast** | fill rate |
| Menu background blur | 5 | **2** | a full-screen blur is costly on a mobile GPU |
| Auto jump | off | **on** | there is no key to hold for a jump |
| Battery mode (`horizon-graphics.txt`) | off | **on** | at most 60 FPS in a world and 30 in menus, half the chunk worker threads |
| GUI scale | auto | auto | 3 on the cover screen held sideways, 6 unfolded |

**Frame limiter and heat.** The Java side reports Android's thermal status (`PowerManager`); the existing limiter then takes the lowest of
the options' cap, battery mode's cap and a thermal cap: nothing up to *light*, **45 FPS** at *moderate*, **30** at *severe*, **20** from *critical*
(`platform::thermal_fps_cap`). With no surface (the app in the background) the loop sleeps instead of spinning.

## Lifecycle: background, rotate, fold

NativeActivity destroys the native window when the app goes to the background and often when the screen changes shape. The game
handles it with the renderer kept as is:

- **`suspended`** (window destroyed): the swapchain (`wgpu::Surface`) is dropped *before the callback returns*, since the window
  is gone after it; held keys and fingers are released; nothing is drawn and the loop waits.
- **`resumed`** (a new window): a new surface is created for the window's size now and configured; the device, pipelines and textures are the old ones.
  If the loading screen was still up it carries on from there.
- **Resized** (rotation, fold, unfold, split screen: the manifest's `configChanges` keep the activity from being recreated): the swapchain is reconfigured.
- Losing focus pauses the game (the *Pause on lost focus* option), and Android's `onDestroy` makes the game save and leave its loop.

The pointer capture follows the game's own mouse grab (captured while playing, free in menus).

## Logs and debugging

On the phone, `adb logcat` has everything. Useful filters:

```sh
adb logcat -s Horizon:V RustStdoutStderr:V AndroidRuntime:E DEBUG:V        # the game's log, its stdout/stderr, Java crashes, native crashes
adb logcat | grep -i -E "horizon|wgpu|vulkan|vk|panic"                    # a wider net
adb logcat -c                                                              # clear first, then reproduce
```

`Horizon` is every log line (`[Render thread] Horizon: ...`, including warnings of wgpu and the Vulkan driver), `RustStdoutStderr` is what the
game prints to stdout and stderr (including panics and, with `RUST_BACKTRACE=1` which the app sets, their backtraces). The same log is
kept in the game folder:

```sh
adb pull /sdcard/Android/data/dev.horizon.android/files/logs/latest.log
adb pull /sdcard/Android/data/dev.horizon.android/files/crash-reports
adb shell ls -la /sdcard/Android/data/dev.horizon.android/files/
```

The renderer logs what it requests and what it gets (`Horizon renderer: requesting the device ... with features [...] and the adapter's limits (...)`,
and a retry without optional features if the driver refuses them); a crash in the graphics driver leaves no panic, so the last
`Horizon renderer:` line is the place it stopped.

On screen: if the game ends with an error or a panic, the activity closes and the launcher screen shows the message (and the crash
report's name); if the process dies without a message, the launcher shows the end of the log. **Share the log** sends it as text.

## Known issues and limits

Untested on a device: everything. In particular the first run on real hardware can show surprises in these areas, in the order the
checklist meets them: the Rust build for `aarch64-linux-android` (dependencies with C code such as `ring`, and `cpal`),
the Vulkan device (features/limits of Adreno), the surface lifecycle, pointer capture, text entry.

Known limits and decisions that will bite:

- **Text entry** uses the game's own on-screen keyboard (tap *Keys*) and hardware keyboards. Android's soft keyboard is not wired in: a
  `NativeActivity` has no IME connection (only ASCII, as key events, and only on some keyboards), so the Java side polls a "show the
  keyboard" bit the Rust side never sets. Moving to `GameActivity` would fix that properly (see [Decisions](#decisions)).
- **No system clipboard** (copy and paste work inside the game only).
- **Controllers:** `gilrs` and the DualSense code are not built on Android. A Bluetooth gamepad is not used yet (Android delivers its buttons as
  key events; mapping them to the game's controller layer is a small step).
- **Mods with code** are off by default (no WebAssembly runtime in the Android build).
- **Shader packs, LOD distance, and high render distances** are the desktop's heavy features; they work in principle, but a phone's budget is far smaller.
- **Display cut-outs and rounded corners:** the game draws under them (`LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS`); the HUD does not avoid them yet.
- **Memory:** the game runs in a normal app process; if Android's low-memory killer ends it in the background the last autosave is what remains
  (the game also saves when the window is destroyed, i.e. when the app goes to the background).
- **Saves and logs live on shared storage** (a FUSE file system on Android 11+): file locks may be missing (the game then runs without its `session.lock`),
  symbolic links cannot be made (the pack cache falls back where it can), and disk access is slower than internal storage.
- Hover and mouse buttons come from the Java side because winit 0.30's Android backend drops them; a stylus, trackpad gestures and mouse back/forward buttons are not mapped.
- Multiplayer, LAN, and online sign-in are the desktop code and untested here.
- Gaps in the touch controls: no pick-block (creative middle click), no swap-hands button, no perspective toggle (F5), no F3.

## What changed in shared code

The desktop must not change; every Android difference is behind `cfg(target_os = "android")`, `cfg!(...)` that is constant false elsewhere,
or code that only an Android event can reach. In `crates/horizon-client`:

- **New modules** (compiled everywhere, used by Android): `platform`, `touch`, `mobile`, `winit_host`, `game/touch`, `game/surface`.
  The touch controls are off on the desktop (`HORIZON_TOUCH=1` turns them on for testing there).
- `lib.rs`: on Android the game loop module is part of the library (`extern crate self as horizon_client;` + `mod game;` + `run_game()`).
- `game.rs`: the event loop comes from `winit_host::event_loop()` (identical `EventLoop::new()` off Android); `resumed`/`suspended` handle a
  surface that comes back; `Touch` events; the loading screen takes a finger as a mouse; the loop sleeps without a surface; the launch arguments can
  come from `horizon-args.txt`; the default resources folder is `resources` (Android only); the mouse grab is virtual on Android.
- `gfx.rs`: `suspend_surface` / `reattach_surface` / `has_surface`; on Android the device request retries without optional features.
- `game/options.rs`: the frame limit takes the thermal cap (none on the desktop). `game/pad.rs`: the move vector can come from the touch stick; `pad_action` is `pub(super)`.
  `game/pad_menu.rs`: three methods `pub(super)` and the keyboard's top-or-bottom test factored out. `osk.rs`: tap hit testing.
- `logging.rs`: a logcat sink and, on Android, the other crates' warnings; locks tolerated. `crash.rs`: the Android game thread counts as the main one.
  `save.rs`: the session lock is skipped where the file system has none (Android). `clipboard.rs`: the game's own copy on Android.
- `Cargo.toml`: `arboard` is not an Android dependency; `winit` gets `android-native-activity` on Android; `horizon-mods`' WebAssembly runtime
  is enabled for every target but Android (where `--features mods` asks for it). `horizon-mods` has a stub (`stub.rs`) with the runtime's surface for builds without it.
- Root `Cargo.toml`: `android/native` is excluded from the workspace (it has its own, like the launcher), so the desktop `Cargo.lock` is untouched.

## Decisions

- **NativeActivity, not GameActivity.** It is built into Android: no AndroidX/Maven dependency, no version coupling between the Java library and
  `android-activity`'s vendored C++ glue (a mismatch there is a native crash at start-up that I could not have tested), and a build that needs only
  the SDK's command-line tools. The price is text input (see above). Switching later means `android-game-activity` in `winit` and the AAR in the APK.
- **No Gradle, no cargo-apk, no xbuild.** The Android Gradle Plugin tracks the JDK and Gradle versions closely (and the user's machine has a JDK 25
  for `horizon-prepare`, which Gradle 8 cannot run on), and `cargo-apk` cannot build Java classes. `cargo-ndk` plus `aapt2`/`javac`/`d8`/`zipalign`/`apksigner`
  is five tools doing what each does well, one script of about a hundred lines, and every failure names the tool.
- **A separate crate for the library** (`android/native`, excluded from the workspace) rather than a `cdylib` crate type on `horizon-client`: the
  desktop builds then do not produce an extra shared library or change a lock file. Its lock is seeded from the desktop one.
- **Java only where Android demands it**, talking to Rust with numbers only (`nativePointer`, `nativeThermal`, ...): no JNI object handling, no `jni`
  crate, so the only `unsafe` code is in `android/native` (logcat, the environment, JNI entry points).
- **The game's own on-screen keyboard** (made for controllers) for text, because it is drawn where it does not cover the field and needs nothing from Android.
- **Touch controls as pure logic** with tests (`touch.rs`), and a thin layer that turns their actions into the same calls the controller layer makes
  (`pad_action("key.jump", ...)`, synthetic pointer events), so key bindings, toggles and every screen's mouse behaviour are reused.
- **Saves, options and logs on external storage** as asked, so `adb pull` reaches them; the cost is shared storage's quirks (above).
- **The wgpu backend** is Vulkan only (the GL backend is not enabled), wgpu's Android handling of `VK_SUBOPTIMAL_KHR` is already in the vendored wgpu-hal, and the device is
  requested with the adapter's own limits, so a mobile GPU cannot fail on limits; only optional features have a fallback.

## What next

1. Run [TESTING.md](TESTING.md) on the phone and fix what the first steps find (compile errors first).
2. Text input through `GameActivity` (or a real `InputConnection` on a `NativeActivity` subclass).
3. Gamepads: map Android's `KEYCODE_BUTTON_*` events to the controller layer.
4. A settings screen for the touch layout, safe-area handling for cut-outs, and a performance pass on the phone (the existing `HORIZON_SPIKES` and the performance overlay work there).
5. Android's clipboard through the Java side; pick-block, swap-hands and perspective buttons.
6. `GameActivity`'s IME, stylus and trackpad gestures, and Android Auto-backup exclusions for `saves/`.
