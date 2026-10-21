# Testing Horizon on the phone

A checklist for the Android build ([ANDROID.md](ANDROID.md)), ordered from "the app launches" to "walk around a world".
Run the steps in order and stop at the first one that fails: each later step needs the earlier ones. For a failure, report the
step number, what you saw, and the **evidence** listed under it.

Nothing in this port has run on a device yet, so step 0 may be a few compile errors rather than a phone problem. Send the first
error (the text from `error[` down to the next blank line), not the whole log.

## Before you start

```sh
adb devices                                  # the phone is listed as "device"
adb logcat -c                                # clear the log before every attempt
adb logcat -s Horizon:V RustStdoutStderr:V AndroidRuntime:E DEBUG:V > horizon.log     # leave this running in a second terminal
```

Evidence commands used below:

```sh
adb pull /sdcard/Android/data/dev.horizon.android/files/logs/latest.log     # the game's log
adb pull /sdcard/Android/data/dev.horizon.android/files/crash-reports       # crash reports, if any
adb shell dumpsys meminfo dev.horizon.android:game                          # memory of the game process
adb shell dumpsys thermalservice | head -30                                 # thermal status
adb shell dumpsys SurfaceFlinger --latency "SurfaceView[dev.horizon.android/dev.horizon.android.HorizonActivity]*"   # frame times
```

## Steps

### Build and install

**0. The APK builds.** `android\build-apk.ps1` (Windows) or `android/build-apk.sh` ends with `Built .../dist/horizon-android-debug.apk`.
- Fails in `cargo ndk`: send the first compiler error. Try `-NoAudio` (cpal) to see if one dependency is the problem; a missing NDK or
  target is named by the script.
- Fails in `aapt2`, `javac`, `d8`, `zipalign` or `apksigner`: send that tool's message (the SDK platform or build-tools version).

**1. It installs.** `adb install -r dist/horizon-android-debug.apk` prints `Success`.
- Fails: send the `Failure [...]` line (INSTALL_FAILED_...).

### The app launches

**2. The launcher screen opens.** Tapping the Horizon icon shows a dark screen with "Horizon", the Android version and your phone's model.
- Crashes at once: `adb logcat -d -s AndroidRuntime:E` (a Java exception) and `step 1`'s install output.

**3. It says the resources are missing.** Before copying anything, the launcher shows "The game's resources are not on this phone yet"
with the folder to copy to, ending in `/Android/data/dev.horizon.android/files/resources`.
- Shows "Resources found" already: you copied them earlier; go on. Shows nothing about resources: send a screenshot.

**4. Start without resources shows the error.** Tap *Start anyway (shows the error)*. The screen goes dark for a moment and returns to the
launcher with "The last run ended with an error: The game's resources are missing...".
- This is a test of the native library loading, `android_main`, logging and the error path: it must work before anything else does.
- Fails: the app closes instead (send `horizon.log`, especially lines with `UnsatisfiedLinkError`, `dlopen` or `android_main`), or the launcher stays
  with no error (send `latest.log` if it exists). Tap *Dismiss* afterwards.

### Resources

**5. The resources copy.** `android\push-resources.ps1 -Prepare -ServerJar <jar>` (or `--resources <prepared folder>` if you have them)
finishes with "Done". The launcher screen now says "Resources found in ...".
- Fails in `horizon-prepare`: the same step on the desktop would fail too (send its message). Fails in `adb push`: send the message;
  check `adb shell ls /sdcard/Android/data/dev.horizon.android/files/resources | head`.

### The game starts

**6. The game window opens.** *Start Horizon*: the screen goes full screen (no status or navigation bars), then shows the loading screen
(the Horizon artwork and a progress bar).
- Black screen forever or the app closes: evidence = `horizon.log` and `latest.log`. Note the **last** `Horizon renderer:` line.

**7. Vulkan works.** `horizon.log` shows `Horizon renderer: <GPU name> (Vulkan, IntegratedGpu)` (an Adreno on the Fold 5), then
`requesting the device ... with features [...]`, `device ready; configuring the surface (WxH Bgra8Unorm|Rgba8Unorm, ...)`,
`presenting the first frame`.
- Stops before `device ready`: send those lines and `adb shell getprop ro.hardware.vulkan` (the driver does not offer what the renderer asks for;
  the log says what was requested and what the adapter offers). If a line says "retrying without the optional features", note it.
- `No Vulkan graphics driver found`: send `adb shell getprop | grep -i vulkan`.

**8. The title menu appears and a tap works.** After loading you see the title menu, and the toolbar down the left edge (Back, Shift, Right,
Up, Down, Keys). Tap *Singleplayer*.
- The menu is there but taps do nothing: touch -> pointer events are not reaching it (send a note and the log).
- The picture is wrong (colours washed out, upside down, stretched): send a screenshot (power + volume down).

### In a world

**9. Create a world with the keyboard.** In *Create New World* tap the name field, tap **Keys**: the on-screen keyboard appears; tap letters,
*Done*. The name changes. Create the world.
- The keyboard does not appear or taps on keys do nothing: send a screenshot.

**10. The world loads and draws.** You see terrain, the HUD (hotbar at the bottom) and the touch controls: stick base at the bottom left, four
buttons (Break, Place, Jump, Sneak) bottom right, Menu/Chat at the top left, Inv/Drop at the top right. Note the frame rate (turn on the
overlay: Options, Video, Overlay "fps").
- Black or garbage terrain, or a crash on load: send `latest.log` and the crash report.
- Controls missing or off the screen: send a screenshot and your screen size (`adb shell wm size`).

**11. Move and look.** Left thumb on the left side drags the stick (the player walks, sprints when you push it to the top). Drag on the right
side to look. **Jump** jumps.
- Walking works but looking does not (or the reverse): note which.

**12. Break and place.** Hold **Break** on a block: it breaks (cracks, then drops an item that you pick up). **Place** puts a block.
- Report if holding does not keep breaking, or placing needs several taps.

**13. Hotbar and inventory.** Tap hotbar slots; swipe along the hotbar. **Inv** opens the inventory: tap a stack, tap an empty slot (it moves).
Toggle **Right** and tap a stack (splits it), toggle **Shift** and tap (moves it across). **Back** closes it.
- Report which of these does not work.

**14. Chat.** Tap **Chat**; the on-screen keyboard opens. Type `/time set day`, *Done*. The command runs. (Close the keyboard with **Keys** or *Back*.)

**15. Pause and the back gesture.** **Menu** (or the system back gesture) opens the pause menu; tap *Back to Game*; swipe back again; tap *Options*,
move a slider, scroll a list with **Up**/**Down**.

### The Android lifecycle

**16. Home and back.** In the world, press Home, wait ten seconds, come back via recents. The game is paused (or running) and **draws again**,
the touch controls work, the world is where you left it.
- Frozen or black: send `horizon.log` from before pressing Home (look for `the window's surface was destroyed` and `is back`).

**17. Rotate.** Turn the phone: the picture re-fits and the controls re-arrange, with no restart. Try it on the pause menu too.

**18. Fold and unfold.** Unfold the Fold 5 in the world, then fold it: each time the picture re-fits in a second or two, the HUD scale changes,
the world is still there. Do it on the title menu too, and once during loading.
- Report: crash, black screen, wrong size, or controls in the wrong place (screenshot + `adb shell wm size`).

**19. Quit and resume.** Pause menu, *Save and Quit to Title*, then swipe the back gesture / Home and open the app again from the launcher:
*Start* returns to the title menu (a new process) and the world is in the list with your changes.

### Mouse and keyboard

**20. Bluetooth keyboard.** Pair it; in the world WASD moves, Space jumps, E opens the inventory, T chats and typing works, Escape pauses.

**21. Bluetooth mouse.** In menus the arrow follows the mouse and clicks work; the wheel scrolls lists. In the world the pointer disappears (captured), moving
the mouse looks around, left click breaks, right click places, the wheel changes the hotbar slot; Escape frees the pointer for the pause menu.
- If the cursor does not hide or moving the mouse does not look: send `horizon.log` and a note of the phone's Android version.

### Walking around

**22. Five minutes in a world.** Set the render distance to 8 and then 12 (Options, Video); walk, fly (creative), build, go into a cave; let it rain.
Note: the frame rate, whether it gets hot, whether chunks pop in late.
- Evidence: the fps overlay values, `adb shell dumpsys meminfo dev.horizon.android:game | head -30` after a few minutes, `adb shell dumpsys thermalservice`,
  and `latest.log` (look for `slow frame`, `video memory is full`, warnings from wgpu).
- The frame limiter drops to 45/30/20 as the phone warms (thermal status moderate/severe/critical): you can see it in the overlay.

**23. Leave the game running ten minutes in your hand.** Report how the phone feels, the battery drop, and any crash or the app being killed.

## Report template

```
Step: <number and title>
Phone / Android version: <e.g. Galaxy Z Fold 5, Android 14 (One UI 6.1)>
Screen: <cover / unfolded>, <portrait / landscape>
What I saw:
Evidence: <horizon.log, latest.log, a screenshot>
```

What the logs mean:

| Line | Meaning |
| --- | --- |
| `Horizon for Android 0.1.0 starting; game folder ...` | the native library started (step 4 passed) |
| `Horizon: first start, wrote the phone defaults ...` | the lighter settings were written |
| `Horizon renderer: ...` | the renderer's progress; a crash in the driver leaves the last one |
| `Horizon: the window's surface was destroyed` / `... is back (WxH)` | the surface lifecycle (steps 16-18) |
| `Horizon: touch control: ...` | an action of the touch controls failed |
| `Horizon: no sound: ...` | audio could not start (the game goes on silent; try `-NoAudio` if it crashes there) |
