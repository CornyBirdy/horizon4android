package dev.horizon.android;

import android.app.Activity;
import android.content.ContentResolver;
import android.content.Intent;
import android.database.Cursor;
import android.net.Uri;
import android.os.Handler;
import android.os.Looper;
import android.provider.DocumentsContract;
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
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.io.RandomAccessFile;
import java.nio.charset.StandardCharsets;
import java.util.ArrayDeque;
import java.util.zip.ZipEntry;
import java.util.zip.ZipInputStream;

/**
 * The app's front door, and the readable error screen: it says whether the game's resources
 * are on the phone and where to put them, starts the game (HorizonActivity, in its own
 * process), and when a run ended badly shows why: the message the game left in
 * last-error.txt, or, if the process died without one (a crash in the graphics driver), the
 * end of the log.
 */
public class LauncherActivity extends Activity {
    private static final int PICK_FOLDER = 41;
    private static final int PICK_ZIP = 42;
    private static final String MANIFEST = "horizon-resources.json";

    private LinearLayout column;
    private final Handler ui = new Handler(Looper.getMainLooper());
    /** Set while resources are being copied in: what it is doing, shown instead of the buttons. */
    private volatile boolean importing;
    private volatile String importStatus = "";
    private TextView importView;
    private String importResult;

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

        if (importing) {
            column.addView(text("Importing the resources. This takes a few minutes; keep the "
                    + "app open.", 15, white, false));
            importView = text(importStatus, 13, Color.rgb(140, 200, 255), true);
            column.addView(importView);
            return;
        }
        if (importResult != null) {
            column.addView(text(importResult, 14, Color.rgb(255, 200, 120), false));
        }
        if (!ready) {
            column.addView(text("The game's resources are not on this phone yet.\n\n"
                    + "Horizon does not include Minecraft's files. On a computer, prepare them "
                    + "from your own Minecraft Java Edition install (the Horizon launcher's "
                    + "Prepare button), copy the prepared folder (the one holding "
                    + MANIFEST + ") or a zip of it to this phone, for instance to its "
                    + "Download folder, then tap one of the import buttons below.",
                    15, white, false));
            column.addView(text("Or push it with adb to:", 13, grey, false));
            column.addView(text(manifest.getParent(), 13, Color.rgb(140, 200, 255), true));
        } else {
            column.addView(text("Resources found in " + manifest.getParent(), 13, grey, false));
        }
        column.addView(button(ready ? "Replace the resources: import a folder"
                : "Import resources from a folder", new View.OnClickListener() {
            @Override
            public void onClick(View view) {
                Intent pick = new Intent(Intent.ACTION_OPEN_DOCUMENT_TREE);
                startActivityForResult(pick, PICK_FOLDER);
            }
        }));
        column.addView(button(ready ? "Replace the resources: import a zip"
                : "Import resources from a zip", new View.OnClickListener() {
            @Override
            public void onClick(View view) {
                Intent pick = new Intent(Intent.ACTION_OPEN_DOCUMENT);
                pick.addCategory(Intent.CATEGORY_OPENABLE);
                pick.setType("*/*");
                startActivityForResult(pick, PICK_ZIP);
            }
        }));

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

    // ---- importing the resources from a folder or zip the player copied to the phone --------

    @Override
    protected void onActivityResult(int request, int result, Intent data) {
        super.onActivityResult(request, result, data);
        if (result != RESULT_OK || data == null || data.getData() == null) {
            return;
        }
        final Uri uri = data.getData();
        final boolean zip = request == PICK_ZIP;
        if (request != PICK_FOLDER && !zip) {
            return;
        }
        importing = true;
        importResult = null;
        importStatus = "Starting";
        show();
        new Thread(new Runnable() {
            @Override
            public void run() {
                String outcome;
                try {
                    importResources(uri, zip);
                    outcome = "Imported. Tap Start Horizon.";
                } catch (Exception e) {
                    outcome = "The import failed: " + e.getMessage();
                }
                final String message = outcome;
                ui.post(new Runnable() {
                    @Override
                    public void run() {
                        importing = false;
                        importResult = message;
                        show();
                    }
                });
            }
        }, "import").start();
    }

    private void progress(final String status) {
        importStatus = status;
        ui.post(new Runnable() {
            @Override
            public void run() {
                if (importView != null && importing) {
                    importView.setText(status);
                }
            }
        });
    }

    private void importResources(Uri source, boolean zip) throws IOException {
        File folder = gameFolder();
        File staging = new File(folder, "resources.importing");
        deleteTree(staging);
        if (!staging.mkdirs()) {
            throw new IOException("could not create " + staging);
        }
        File root;
        long[] bytes = new long[1];
        if (zip) {
            progress("Unpacking the zip");
            try (InputStream in = getContentResolver().openInputStream(source)) {
                if (in == null) {
                    throw new IOException("could not open the file");
                }
                unzip(in, staging, bytes);
            }
            root = findManifestDir(staging, 4);
        } else {
            String treeId = DocumentsContract.getTreeDocumentId(source);
            progress("Looking for " + MANIFEST);
            String docId = findManifestDoc(source, treeId);
            if (docId == null) {
                deleteTree(staging);
                throw new IOException("no " + MANIFEST + " in that folder. Pick the prepared "
                        + "folder itself (the one that holds " + MANIFEST + ").");
            }
            copyTree(source, docId, staging, bytes);
            root = staging;
        }
        if (root == null || !new File(root, MANIFEST).isFile()) {
            String found = describe(staging);
            deleteTree(staging);
            throw new IOException("no " + MANIFEST + " in what was copied ("
                    + megabytes(bytes[0]) + ").\nWhat came out: " + found + "\n"
                    + "Pack the folder that holds " + MANIFEST + " (android\\make-phone-resources"
                    + ".bat does) and pick that zip.");
        }
        progress("Putting the files in place");
        File target = new File(folder, "resources");
        deleteTree(target);
        if (!root.renameTo(target)) {
            throw new IOException("could not move the files into " + target);
        }
        deleteTree(staging);
    }

    /** The first few names in a folder, for an error message. */
    private static String describe(File dir) {
        String[] names = dir.list();
        if (names == null || names.length == 0) {
            return "nothing (the file is not a readable zip, or it is empty)";
        }
        java.util.Arrays.sort(names);
        StringBuilder out = new StringBuilder();
        for (int i = 0; i < names.length && i < 8; i++) {
            out.append(i > 0 ? ", " : "").append(names[i]);
        }
        if (names.length > 8) {
            out.append(", ... (").append(names.length).append(" items)");
        }
        return out.toString();
    }

    private void unzip(InputStream in, File into, long[] bytes) throws IOException {
        String base = into.getCanonicalPath() + File.separator;
        byte[] buffer = new byte[1 << 20];
        long shown = 0;
        try (ZipInputStream zip = new ZipInputStream(in)) {
            ZipEntry entry;
            while ((entry = zip.getNextEntry()) != null) {
                File out = new File(into, entry.getName());
                if (!out.getCanonicalPath().startsWith(base)) {
                    continue;
                }
                if (entry.isDirectory()) {
                    out.mkdirs();
                    continue;
                }
                File parent = out.getParentFile();
                if (parent != null) {
                    parent.mkdirs();
                }
                try (OutputStream o = new FileOutputStream(out)) {
                    int n;
                    while ((n = zip.read(buffer)) > 0) {
                        o.write(buffer, 0, n);
                        bytes[0] += n;
                    }
                }
                if (bytes[0] - shown > (8 << 20)) {
                    shown = bytes[0];
                    progress(megabytes(bytes[0]) + " unpacked");
                }
            }
        }
    }

    private static File findManifestDir(File dir, int depth) {
        if (new File(dir, MANIFEST).isFile()) {
            return dir;
        }
        File[] children = dir.listFiles();
        if (children == null || depth == 0) {
            return null;
        }
        for (File child : children) {
            if (child.isDirectory()) {
                File found = findManifestDir(child, depth - 1);
                if (found != null) {
                    return found;
                }
            }
        }
        return null;
    }

    /** Document ids of a folder's children as {id, name, mime}, or an empty list. */
    private java.util.List<String[]> children(Uri tree, String docId) {
        java.util.List<String[]> list = new java.util.ArrayList<>();
        Uri uri = DocumentsContract.buildChildDocumentsUriUsingTree(tree, docId);
        try (Cursor cursor = getContentResolver().query(uri, new String[] {
                DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                DocumentsContract.Document.COLUMN_MIME_TYPE}, null, null, null)) {
            while (cursor != null && cursor.moveToNext()) {
                list.add(new String[] {cursor.getString(0), cursor.getString(1),
                        cursor.getString(2)});
            }
        } catch (RuntimeException e) {
            // an unreadable folder counts as empty
        }
        return list;
    }

    private static boolean isDir(String mime) {
        return DocumentsContract.Document.MIME_TYPE_DIR.equals(mime);
    }

    /** The folder (as a document id) that holds the manifest: the picked one, or below it. */
    private String findManifestDoc(Uri tree, String start) {
        ArrayDeque<String[]> queue = new ArrayDeque<>();
        queue.add(new String[] {start, "0"});
        int visited = 0;
        while (!queue.isEmpty() && visited++ < 300) {
            String[] item = queue.poll();
            int depth = Integer.parseInt(item[1]);
            for (String[] child : children(tree, item[0])) {
                if (MANIFEST.equals(child[1]) && !isDir(child[2])) {
                    return item[0];
                }
            }
            if (depth < 3) {
                for (String[] child : children(tree, item[0])) {
                    if (isDir(child[2])) {
                        queue.add(new String[] {child[0], Integer.toString(depth + 1)});
                    }
                }
            }
        }
        return null;
    }

    private void copyTree(Uri tree, String docId, File into, long[] bytes) throws IOException {
        ContentResolver resolver = getContentResolver();
        byte[] buffer = new byte[1 << 20];
        for (String[] child : children(tree, docId)) {
            String name = child[1];
            if (name == null || name.isEmpty() || name.equals(".") || name.equals("..")
                    || name.indexOf('/') >= 0) {
                continue;
            }
            File out = new File(into, name);
            if (isDir(child[2])) {
                if (!out.isDirectory() && !out.mkdirs()) {
                    throw new IOException("could not create " + out);
                }
                copyTree(tree, child[0], out, bytes);
                continue;
            }
            Uri file = DocumentsContract.buildDocumentUriUsingTree(tree, child[0]);
            try (InputStream in = resolver.openInputStream(file);
                    OutputStream o = new FileOutputStream(out)) {
                if (in == null) {
                    throw new IOException("could not open " + name);
                }
                int n;
                while ((n = in.read(buffer)) > 0) {
                    o.write(buffer, 0, n);
                    bytes[0] += n;
                }
            }
            progress(megabytes(bytes[0]) + " copied\n" + name);
        }
    }

    private static String megabytes(long bytes) {
        return (bytes >> 20) + " MB";
    }

    private static void deleteTree(File file) {
        File[] children = file.listFiles();
        if (children != null) {
            for (File child : children) {
                deleteTree(child);
            }
        }
        file.delete();
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
