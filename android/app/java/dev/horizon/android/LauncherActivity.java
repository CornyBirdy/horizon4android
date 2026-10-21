package dev.horizon.android;

import android.app.Activity;
import android.content.Intent;
import android.graphics.Color;
import android.graphics.Typeface;
import android.os.Build;
import android.os.Bundle;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.View;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;

import java.io.File;
import java.io.IOException;
import java.io.RandomAccessFile;
import java.nio.charset.StandardCharsets;

/**
 * The app's front door, and the readable error screen: it says whether the game's resources
 * are on the phone and where to put them, starts the game (HorizonActivity, in its own
 * process), and when a run ended badly shows why: the message the game left in
 * last-error.txt, or, if the process died without one (a crash in the graphics driver), the
 * end of the log.
 */
public class LauncherActivity extends Activity {
    private LinearLayout column;

    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        ScrollView scroll = new ScrollView(this);
        scroll.setBackgroundColor(Color.rgb(18, 18, 22));
        scroll.setFillViewport(true);
        column = new LinearLayout(this);
        column.setOrientation(LinearLayout.VERTICAL);
        int pad = dp(20);
        column.setPadding(pad, pad + dp(8), pad, pad);
        scroll.addView(column);
        setContentView(scroll);
    }

    @Override
    protected void onResume() {
        super.onResume();
        show();
    }

    private int dp(int value) {
        return (int) TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, value,
                getResources().getDisplayMetrics());
    }

    private File gameFolder() {
        File dir = getExternalFilesDir(null);
        return dir != null ? dir : getFilesDir();
    }

    private TextView text(String body, int sp, int color, boolean mono) {
        TextView view = new TextView(this);
        view.setText(body);
        view.setTextSize(TypedValue.COMPLEX_UNIT_SP, sp);
        view.setTextColor(color);
        view.setTextIsSelectable(true);
        if (mono) {
            view.setTypeface(Typeface.MONOSPACE);
        }
        view.setPadding(0, dp(6), 0, dp(6));
        return view;
    }

    private Button button(String label, View.OnClickListener action) {
        Button button = new Button(this);
        button.setText(label);
        button.setAllCaps(false);
        button.setOnClickListener(action);
        LinearLayout.LayoutParams params = new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT);
        params.topMargin = dp(8);
        button.setLayoutParams(params);
        return button;
    }

    private void show() {
        column.removeAllViews();
        final File folder = gameFolder();
        File error = new File(folder, "last-error.txt");
        File marker = new File(folder, "running.marker");
        File manifest = new File(new File(folder, "resources"), "horizon-resources.json");
        boolean ready = manifest.isFile();
        int white = Color.WHITE;
        int grey = Color.rgb(170, 170, 180);

        TextView title = text("Horizon", 30, white, false);
        title.setGravity(Gravity.START);
        column.addView(title);
        column.addView(text("Minecraft Java Edition 26.3, rewritten in Rust. Android "
                + Build.VERSION.RELEASE + ", " + Build.MANUFACTURER + " " + Build.MODEL + ".",
                14, grey, false));

        if (error.isFile()) {
            column.addView(text("The last run ended with an error:", 16, Color.rgb(255, 140, 120),
                    false));
            column.addView(text(read(error, 6000), 13, white, true));
        } else if (marker.isFile()) {
            column.addView(text("The last run stopped without saying why (the game or the "
                    + "graphics driver crashed). The end of the log:", 16,
                    Color.rgb(255, 140, 120), false));
            column.addView(text(tail(new File(new File(folder, "logs"), "latest.log"), 6000),
                    12, white, true));
        }

        if (!ready) {
            column.addView(text("The game's resources are not on this phone yet.\n\n"
                    + "Horizon does not include Minecraft's files. On a computer, prepare them "
                    + "from your own Minecraft Java Edition install with horizon-prepare, then "
                    + "copy the prepared folder (the one holding horizon-resources.json) here:",
                    15, white, false));
            column.addView(text(manifest.getParent(), 13, Color.rgb(140, 200, 255), true));
            column.addView(text("android/push-resources does both steps; ANDROID.md has the "
                    + "details. Then come back to this screen.", 14, grey, false));
        } else {
            column.addView(text("Resources found in " + manifest.getParent(), 13, grey, false));
        }

        column.addView(button(ready ? "Start Horizon" : "Start anyway (shows the error)",
                new View.OnClickListener() {
                    @Override
                    public void onClick(View view) {
                        startActivity(new Intent(LauncherActivity.this, HorizonActivity.class));
                    }
                }));
        column.addView(button("Share the log", new View.OnClickListener() {
            @Override
            public void onClick(View view) {
                Intent send = new Intent(Intent.ACTION_SEND);
                send.setType("text/plain");
                send.putExtra(Intent.EXTRA_SUBJECT, "Horizon log");
                send.putExtra(Intent.EXTRA_TEXT, tail(
                        new File(new File(folder, "logs"), "latest.log"), 60000));
                startActivity(Intent.createChooser(send, "Share the log"));
            }
        }));
        if (error.isFile() || marker.isFile()) {
            column.addView(button("Dismiss", new View.OnClickListener() {
                @Override
                public void onClick(View view) {
                    new File(folder, "last-error.txt").delete();
                    new File(folder, "running.marker").delete();
                    show();
                }
            }));
        }
        column.addView(text("Game folder: " + folder + "\nLog: logs/latest.log in it, or "
                + "adb logcat -s Horizon RustStdoutStderr", 12, grey, true));
    }

    private static String read(File file, int max) {
        return tail(file, max).trim();
    }

    /** The last {@code max} bytes of a text file, from the start of a line. */
    private static String tail(File file, int max) {
        if (!file.isFile()) {
            return "(" + file.getName() + " does not exist)";
        }
        try (RandomAccessFile in = new RandomAccessFile(file, "r")) {
            long length = in.length();
            int count = (int) Math.min(length, max);
            byte[] bytes = new byte[count];
            in.seek(length - count);
            in.readFully(bytes);
            String text = new String(bytes, StandardCharsets.UTF_8);
            if (length > count) {
                int newline = text.indexOf('\n');
                if (newline >= 0) {
                    text = text.substring(newline + 1);
                }
            }
            return text;
        } catch (IOException e) {
            return "(could not read " + file.getName() + ": " + e + ")";
        }
    }
}
