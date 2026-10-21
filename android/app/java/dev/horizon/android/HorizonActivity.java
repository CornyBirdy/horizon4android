package dev.horizon.android;

import android.app.NativeActivity;
import android.content.Context;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.os.PowerManager;
import android.os.Process;
import android.os.SystemClock;
import android.view.InputDevice;
import android.view.KeyEvent;
import android.view.MotionEvent;
import android.view.View;
import android.view.WindowInsets;
import android.view.WindowInsetsController;
import android.view.WindowManager;
import android.view.inputmethod.InputMethodManager;

/**
 * The game's activity: Android's own NativeActivity (the Rust library runs the game on a thread
 * of its own) plus the few things NativeActivity cannot do, which winit's Android backend
 * does not do either: a real mouse (hover, buttons, wheel, and pointer capture for mouse
 * look), the system back gesture as Escape, the soft keyboard, the device's thermal state,
 * the immersive full screen, and telling the game to save when the activity is destroyed.
 *
 * Everything crosses to Rust as numbers through the four native methods below
 * (android/native/src/lib.rs).
 */
public class HorizonActivity extends NativeActivity {
    static {
        System.loadLibrary("horizon_android");
    }

    /** The thermal status ({@code PowerManager.THERMAL_STATUS_*}). */
    private static native void nativeThermal(int status);

    /** What the game asks for, as bits: 1 captures the pointer, 2 shows the soft keyboard. */
    private static native int nativeWants();

    /**
     * A mouse event. kind 0: the pointer is at (a, b) pixels. 1: it moved by (a, b) while
     * captured. 2: button c (0 left, 1 right, 2 middle) went down if a is positive, else up.
     * 3: the wheel turned by (a, b) lines.
     */
    private static native void nativePointer(int kind, float a, float b, int c);

    /** The activity is being destroyed; the game saves and leaves. */
    private static native void nativeExit();

    private final Handler handler = new Handler(Looper.getMainLooper());
    private PowerManager.OnThermalStatusChangedListener thermalListener;
    private int wants = 0;
    private boolean captured = false;
    private long captureAsked = 0;
    /** The mouse buttons last reported down, as MotionEvent.BUTTON_* bits. */
    private int buttons = 0;

    private final Runnable poll = new Runnable() {
        @Override
        public void run() {
            int now = nativeWants();
            boolean wantCapture = (now & 1) != 0 && hasWindowFocus();
            if (wantCapture != captured) {
                // A request that did not take (no focus yet) is repeated twice a second.
                long t = SystemClock.uptimeMillis();
                if (!wantCapture || t - captureAsked > 500) {
                    captureAsked = t;
                    capture(wantCapture);
                }
            }
            if ((now & 2) != (wants & 2)) {
                showKeyboard((now & 2) != 0);
            }
            wants = now;
            handler.postDelayed(this, 50);
        }
    };

    private final View.OnCapturedPointerListener captureListener =
            new View.OnCapturedPointerListener() {
                @Override
                public boolean onCapturedPointer(View view, MotionEvent event) {
                    captured(event);
                    return true;
                }
            };

    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        // Draw under the camera cut-out, as the game fills the screen.
        WindowManager.LayoutParams params = getWindow().getAttributes();
        params.layoutInDisplayCutoutMode =
                WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS;
        getWindow().setAttributes(params);
        immersive();
        watchThermal();
        handler.post(poll);
    }

    @Override
    protected void onDestroy() {
        handler.removeCallbacksAndMessages(null);
        if (thermalListener != null && Build.VERSION.SDK_INT >= 29) {
            ((PowerManager) getSystemService(Context.POWER_SERVICE))
                    .removeThermalStatusListener(thermalListener);
        }
        // onDestroy of NativeActivity waits for the game thread to end: tell it first.
        nativeExit();
        super.onDestroy();
        // The game keeps process-wide state and runs once per process (it lives in its own,
        // ":game"); the launcher is in the main process and stays.
        if (isFinishing()) {
            Process.killProcess(Process.myPid());
        }
    }

    @Override
    public void onWindowFocusChanged(boolean hasFocus) {
        super.onWindowFocusChanged(hasFocus);
        if (hasFocus) {
            immersive();
        }
    }

    @Override
    public void onPointerCaptureChanged(boolean hasCapture) {
        super.onPointerCaptureChanged(hasCapture);
        captured = hasCapture;
        releaseButtons();
    }

    private void immersive() {
        WindowInsetsController controller = getWindow().getInsetsController();
        if (controller != null) {
            controller.hide(WindowInsets.Type.systemBars());
            controller.setSystemBarsBehavior(
                    WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE);
        }
    }

    private void watchThermal() {
        if (Build.VERSION.SDK_INT < 29) {
            return;
        }
        PowerManager power = (PowerManager) getSystemService(Context.POWER_SERVICE);
        nativeThermal(power.getCurrentThermalStatus());
        thermalListener = new PowerManager.OnThermalStatusChangedListener() {
            @Override
            public void onThermalStatusChanged(int status) {
                nativeThermal(status);
            }
        };
        power.addThermalStatusListener(getMainExecutor(), thermalListener);
    }

    private void capture(boolean on) {
        View view = getWindow().getDecorView();
        if (on) {
            view.setOnCapturedPointerListener(captureListener);
            view.requestFocus();
            view.requestPointerCapture();
        } else {
            view.releasePointerCapture();
            captured = false;
        }
    }

    private void showKeyboard(boolean show) {
        InputMethodManager methods =
                (InputMethodManager) getSystemService(Context.INPUT_METHOD_SERVICE);
        View view = getWindow().getDecorView();
        if (show) {
            methods.showSoftInput(view, 0);
        } else {
            methods.hideSoftInputFromWindow(view.getWindowToken(), 0);
        }
    }

    // ---- the system back gesture is Escape -------------------------------------------------

    @Override
    public boolean dispatchKeyEvent(KeyEvent event) {
        if (event.getKeyCode() == KeyEvent.KEYCODE_BACK) {
            return super.dispatchKeyEvent(new KeyEvent(
                    event.getDownTime(), event.getEventTime(), event.getAction(),
                    KeyEvent.KEYCODE_ESCAPE, event.getRepeatCount(), event.getMetaState(),
                    event.getDeviceId(), event.getScanCode(), event.getFlags(),
                    event.getSource()));
        }
        return super.dispatchKeyEvent(event);
    }

    // ---- the mouse -------------------------------------------------------------------------
    // NativeActivity's input queue turns a mouse into a touch pointer and drops its hover,
    // wheel and extra buttons, so the real mouse is taken here, before the queue.

    private static boolean isMouse(MotionEvent event) {
        return (event.getSource() & InputDevice.SOURCE_MOUSE) == InputDevice.SOURCE_MOUSE;
    }

    @Override
    public boolean dispatchTouchEvent(MotionEvent event) {
        if (isMouse(event)) {
            mouse(event);
            return true;
        }
        return super.dispatchTouchEvent(event);
    }

    @Override
    public boolean dispatchGenericMotionEvent(MotionEvent event) {
        if (isMouse(event)) {
            mouse(event);
            return true;
        }
        return super.dispatchGenericMotionEvent(event);
    }

    /** A mouse event while the pointer is free: its position, buttons and wheel. */
    private void mouse(MotionEvent event) {
        if (event.getActionMasked() == MotionEvent.ACTION_SCROLL) {
            nativePointer(3, event.getAxisValue(MotionEvent.AXIS_HSCROLL),
                    event.getAxisValue(MotionEvent.AXIS_VSCROLL), 0);
            return;
        }
        nativePointer(0, event.getX(), event.getY(), 0);
        buttons(event.getButtonState());
    }

    /** A mouse event while the pointer is captured: relative motion, buttons and wheel. */
    private void captured(MotionEvent event) {
        if (event.getActionMasked() == MotionEvent.ACTION_SCROLL) {
            nativePointer(3, event.getAxisValue(MotionEvent.AXIS_HSCROLL),
                    event.getAxisValue(MotionEvent.AXIS_VSCROLL), 0);
            return;
        }
        // A captured mouse reports its movement, not a position, in X and Y.
        if ((event.getSource() & InputDevice.SOURCE_MOUSE_RELATIVE)
                == InputDevice.SOURCE_MOUSE_RELATIVE) {
            float dx = event.getX();
            float dy = event.getY();
            if (dx != 0 || dy != 0) {
                nativePointer(1, dx, dy, 0);
            }
        }
        buttons(event.getButtonState());
    }

    /** Sends the buttons that went down or up since the last event. */
    private void buttons(int state) {
        int changed = state ^ buttons;
        if (changed == 0) {
            return;
        }
        int[][] map = {
                {MotionEvent.BUTTON_PRIMARY, 0},
                {MotionEvent.BUTTON_SECONDARY, 1},
                {MotionEvent.BUTTON_TERTIARY, 2},
        };
        for (int[] entry : map) {
            if ((changed & entry[0]) != 0) {
                nativePointer(2, (state & entry[0]) != 0 ? 1f : 0f, 0f, entry[1]);
            }
        }
        buttons = state;
    }

    /** Capture started or ended: buttons held through it are let go. */
    private void releaseButtons() {
        if (buttons != 0) {
            buttons(0);
        }
    }
}
