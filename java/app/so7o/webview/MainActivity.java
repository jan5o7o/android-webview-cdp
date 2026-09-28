package app.so7o.webview;

import android.Manifest;
import android.app.Activity;
import android.app.AppOpsManager;
import android.app.Dialog;
import android.content.ActivityNotFoundException;
import android.content.ClipData;
import android.content.ContentValues;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.media.AudioManager;
import android.net.Uri;
import android.os.Bundle;
import android.os.Message;
import android.provider.MediaStore;
import android.util.Base64;
import android.util.Log;
import android.view.ViewGroup;
import android.webkit.DownloadListener;
import android.webkit.JavascriptInterface;
import android.webkit.PermissionRequest;
import android.webkit.ValueCallback;
import android.webkit.WebChromeClient;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.Toast;

import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;

/**
 * Minimal WebView shell whose only trick is: remote debugging is on, so the
 * page can be driven over the Chrome DevTools Protocol from Termux.
 *
 * The DevTools server listens on the abstract unix socket
 *   webview_devtools_remote_<pid>
 * which cannot be reached from another app (SELinux), so the client side is
 * `adb forward tcp:9222 localabstract:webview_devtools_remote_<pid>` (see
 * cdp-webview.sh).
 *
 * Beyond that it answers the gates a bare WebView refuses by default. All of
 * these are silent refusals otherwise — the page only sees a generic error:
 *
 *   onPermissionRequest   camera (RESOURCE_VIDEO_CAPTURE), microphone
 *                         (RESOURCE_AUDIO_CAPTURE); EME and MIDI sysex are
 *                         denied on purpose
 *   onShowFileChooser     <input type=file>, including capture=camera
 *   DownloadListener      <a download>, blob: and data: URLs
 *   onCreateWindow        window.open / target=_blank (a real second WebView,
 *                         which is also a second CDP target)
 */
public class MainActivity extends Activity {

    private static final String TAG = "So7oWebView";
    private static final int REQ_MEDIA = 4701;   // CAMERA and/or RECORD_AUDIO
    private static final int REQ_FILE = 4702;    // onShowFileChooser

    private WebView web;
    private WebChromeClient chrome;

    /** A page's getUserMedia() request, parked while Android asks the user. */
    private PermissionRequest pendingMediaRequest;
    private String[] pendingMediaResources;

    /** A page's file chooser, parked while the picker/camera activity is up. */
    private ValueCallback<Uri[]> filePathCallback;
    private Uri captureOutputUri;
    private String lastFileChooser = "{}";

    /** window.open() target: its own WebView (and its own CDP target). */
    private Dialog popup;
    private WebView popupWeb;

    @Override
    protected void onCreate(Bundle state) {
        // Must run before any WebView is constructed. Global to the process.
        WebView.setWebContentsDebuggingEnabled(true);
        final int pid = android.os.Process.myPid();
        Log.i(TAG, "devtools socket = webview_devtools_remote_" + pid);

        super.onCreate(state);

        // Freeze-exempt while backgrounded (see KeepAliveService) — without this
        // the DevTools socket stops accepting once the app leaves the foreground.
        startForegroundService(new Intent(this, KeepAliveService.class));

        web = new WebView(this);
        setContentView(web, new ViewGroup.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT));

        WebSettings s = web.getSettings();
        s.setJavaScriptEnabled(true);
        s.setDomStorageEnabled(true);
        // Live camera previews must not wait for a tap; the page is local/trusted.
        s.setMediaPlaybackRequiresUserGesture(false);
        // window.open()/target=_blank: without this the *current* view navigates
        // instead of calling onCreateWindow.
        s.setSupportMultipleWindows(true);
        s.setJavaScriptCanOpenWindowsAutomatically(true);

        chrome = new Chrome();
        web.setWebChromeClient(chrome);
        web.setWebViewClient(new WebViewClient());
        web.setDownloadListener(new Downloads());
        web.addJavascriptInterface(new Bridge(), "so7o");
        web.loadUrl("file:///android_asset/index.html");

        // Publish the DevTools socket on 127.0.0.1 so clients can skip adb forward.
        new RelayServer().start();
    }

    // ------------------------------------------------------------------ gates

    /**
     * Camera and microphone. A WebView refuses every permission request unless
     * the host answers here, and Android additionally requires the app to hold
     * the matching runtime permission — so grant only after both are true.
     * EME (RESOURCE_PROTECTED_MEDIA_ID) and MIDI sysex are denied on purpose.
     */
    private class Chrome extends WebChromeClient {
        @Override
        public void onPermissionRequest(final PermissionRequest request) {
            runOnUiThread(new Runnable() {
                @Override
                public void run() {
                    boolean video = false, audio = false;
                    for (String res : request.getResources()) {
                        if (PermissionRequest.RESOURCE_VIDEO_CAPTURE.equals(res)) video = true;
                        else if (PermissionRequest.RESOURCE_AUDIO_CAPTURE.equals(res)) audio = true;
                    }
                    if (!video && !audio) {
                        Log.i(TAG, "denying non capture request: " + java.util.Arrays.toString(request.getResources()));
                        request.deny();
                        return;
                    }
                    String[] wanted = new String[(video ? 1 : 0) + (audio ? 1 : 0)];
                    int i = 0;
                    if (video) wanted[i++] = Manifest.permission.CAMERA;
                    if (audio) wanted[i] = Manifest.permission.RECORD_AUDIO;

                    boolean allGranted = true;
                    for (String perm : wanted) {
                        if (checkSelfPermission(perm) != PackageManager.PERMISSION_GRANTED) allGranted = false;
                    }
                    if (allGranted) {
                        Log.i(TAG, "granting " + java.util.Arrays.toString(wanted) + " to " + request.getOrigin());
                        request.grant(resourcesFor(video, audio));
                    } else {
                        // Park the page's request while Android's own prompt is answered.
                        pendingMediaRequest = request;
                        pendingMediaResources = resourcesFor(video, audio);
                        requestPermissions(wanted, REQ_MEDIA);
                    }
                }
            });
        }

        @Override
        public void onPermissionRequestCanceled(PermissionRequest request) {
            if (pendingMediaRequest == request) pendingMediaRequest = null;
        }

        /**
         * <input type=file>, and the `capture` variant that wants a fresh photo.
         * No FileProvider is involved: for a capture request we contribute a
         * MediaStore entry and let the camera app write into it (allowed on
         * API 29+ without storage permissions).
         */
        @Override
        public boolean onShowFileChooser(WebView view, ValueCallback<Uri[]> callback, FileChooserParams params) {
            Log.i(TAG, "file chooser: accept=" + java.util.Arrays.toString(params.getAcceptTypes())
                    + " capture=" + params.isCaptureEnabled() + " mode=" + params.getMode());
            if (filePathCallback != null) filePathCallback.onReceiveValue(null); // docs: cancel a stale one
            filePathCallback = callback;
            captureOutputUri = null;
            lastFileChooser = "{\"acceptTypes\":" + jsonStrings(params.getAcceptTypes())
                    + ",\"captureEnabled\":" + params.isCaptureEnabled()
                    + ",\"multiple\":" + (params.getMode() == FileChooserParams.MODE_OPEN_MULTIPLE)
                    + ",\"at\":" + System.currentTimeMillis() + "}";

            Intent content = new Intent(Intent.ACTION_GET_CONTENT);
            content.addCategory(Intent.CATEGORY_OPENABLE);
            content.setType(pickType(params.getAcceptTypes()));
            if (params.getMode() == FileChooserParams.MODE_OPEN_MULTIPLE) {
                content.putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true);
            }
            Intent chooser = Intent.createChooser(content,
                    params.isCaptureEnabled() ? "Take a photo or pick a file" : "Pick a file");

            if (params.isCaptureEnabled()) {
                try {
                    ContentValues v = new ContentValues();
                    v.put(MediaStore.Images.Media.DISPLAY_NAME, "so7o-capture-" + System.currentTimeMillis() + ".jpg");
                    v.put(MediaStore.Images.Media.MIME_TYPE, "image/jpeg");
                    captureOutputUri = getContentResolver().insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, v);
                } catch (Exception e) {
                    Log.w(TAG, "could not create the capture target", e);
                }
                if (captureOutputUri != null) {
                    Intent camera = new Intent(MediaStore.ACTION_IMAGE_CAPTURE);
                    camera.putExtra(MediaStore.EXTRA_OUTPUT, captureOutputUri);
                    camera.addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION);
                    chooser.putExtra(Intent.EXTRA_INITIAL_INTENTS, new Intent[] { camera });
                }
            }

            try {
                startActivityForResult(chooser, REQ_FILE);
                return true;
            } catch (ActivityNotFoundException e) {
                Log.w(TAG, "no activity can answer the file chooser", e);
                filePathCallback = null;
                callback.onReceiveValue(null);
                return false;
            }
        }

        /**
         * window.open / target=_blank. A real second WebView in a dialog: it gets
         * its own DevTools target, and the current page is left alone.
         */
        @Override
        public boolean onCreateWindow(WebView view, boolean isDialog, boolean isUserGesture, Message resultMsg) {
            Log.i(TAG, "window.open -> popup webview (dialog=" + isDialog + " gesture=" + isUserGesture + ")");
            final WebView child = new WebView(MainActivity.this);
            WebSettings cs = child.getSettings();
            cs.setJavaScriptEnabled(true);
            cs.setDomStorageEnabled(true);
            cs.setMediaPlaybackRequiresUserGesture(false);
            cs.setSupportMultipleWindows(true);
            cs.setJavaScriptCanOpenWindowsAutomatically(true);
            child.setWebChromeClient(chrome);
            child.setWebViewClient(new WebViewClient());
            child.setDownloadListener(new Downloads());

            final Dialog d = new Dialog(MainActivity.this, android.R.style.Theme_Black_NoTitleBar_Fullscreen);
            d.setContentView(child, new ViewGroup.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));
            d.setOnDismissListener(new android.content.DialogInterface.OnDismissListener() {
                @Override
                public void onDismiss(android.content.DialogInterface dialog) {
                    child.destroy();
                    if (popupWeb == child) { popupWeb = null; popup = null; }
                }
            });
            d.show();
            popup = d;
            popupWeb = child;

            WebView.WebViewTransport transport = (WebView.WebViewTransport) resultMsg.obj;
            transport.setWebView(child);
            resultMsg.sendToTarget();
            return true;
        }

        @Override
        public void onCloseWindow(WebView window) {
            if (popupWeb == window && popup != null) popup.dismiss();
        }
    }

    // -------------------------------------------------------------- downloads

    /**
     * <a download> and friends. Without a listener these are silent no-ops.
     * blob:/data: URLs only exist inside the renderer, so those are converted to
     * a data: URL in the page and handed back through the JS bridge.
     */
    private class Downloads implements DownloadListener {
        @Override
        public void onDownloadStart(String url, String userAgent, String disposition, String mime, long size) {
            String name = guessName(disposition, url, mime);
            Log.i(TAG, "download: " + url + " -> " + name + " (" + mime + ", " + size + "B)");
            if (url.startsWith("blob:") || url.startsWith("data:")) {
                String js = "(function(){fetch(" + jsonString(url) + ").then(function(r){return r.blob()})"
                        + ".then(function(b){var fr=new FileReader();fr.onload=function(){so7o.saveDataUrl("
                        + jsonString(name) + ", fr.result)};fr.readAsDataURL(b)})"
                        + ".catch(function(e){so7o.toast('download failed: '+e.message)})})()";
                web.evaluateJavascript(js, null);
                return;
            }
            downloadInBackground(url, mime, name);
        }
    }

    private void downloadInBackground(final String url, final String mime, final String name) {
        new Thread(new Runnable() {
            @Override
            public void run() {
                InputStream in = null;
                try {
                    String type = mime == null || mime.isEmpty() ? "application/octet-stream" : mime;
                    if (url.startsWith("content:")) {
                        in = getContentResolver().openInputStream(Uri.parse(url));
                    } else {
                        HttpURLConnection c = (HttpURLConnection) new URL(url).openConnection();
                        c.setInstanceFollowRedirects(true);
                        c.setRequestProperty("User-Agent", web.getSettings().getUserAgentString());
                        c.connect();
                        int code = c.getResponseCode();
                        if (code < 200 || code >= 300) throw new IOException("HTTP " + code);
                        in = c.getInputStream();
                    }
                    if (in == null) throw new IOException("nothing to read");
                    Uri saved = save(name, type, in);
                    Log.i(TAG, "saved " + saved);
                    toastOnUi("saved to Downloads/" + name);
                } catch (Exception e) {
                    Log.w(TAG, "download failed", e);
                    toastOnUi("download failed: " + e.getMessage());
                } finally {
                    try { if (in != null) in.close(); } catch (IOException ignored) { }
                }
            }
        }).start();
    }

    /** Stream into the public Downloads collection (API 29+ needs no permission). */
    private Uri save(String name, String mime, InputStream in) throws IOException {
        ContentValues v = new ContentValues();
        v.put(MediaStore.Downloads.DISPLAY_NAME, name);
        v.put(MediaStore.Downloads.MIME_TYPE, mime);
        v.put(MediaStore.Downloads.IS_PENDING, 1);
        Uri item = getContentResolver().insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, v);
        if (item == null) throw new IOException("MediaStore refused the insert");
        OutputStream out = null;
        try {
            out = getContentResolver().openOutputStream(item);
            if (out == null) throw new IOException("no output stream");
            byte[] buf = new byte[8192];
            int n;
            while ((n = in.read(buf)) > 0) out.write(buf, 0, n);
        } finally {
            if (out != null) out.close();
        }
        ContentValues done = new ContentValues();
        done.put(MediaStore.Downloads.IS_PENDING, 0);
        getContentResolver().update(item, done, null, null);
        return item;
    }

    private static String guessName(String disposition, String url, String mime) {
        if (disposition != null) {
            int i = disposition.toLowerCase().indexOf("filename=");
            if (i >= 0) {
                String name = disposition.substring(i + 9).trim().replace("\"", "");
                if (!name.isEmpty()) return name;
            }
        }
        String path = url.startsWith("data:") || url.startsWith("blob:") ? "" : Uri.parse(url).getLastPathSegment();
        if (path != null && !path.isEmpty() && path.contains(".")) return path;
        String ext = "image/jpeg".equals(mime) ? ".jpg" : "image/png".equals(mime) ? ".png"
                : "text/html".equals(mime) ? ".html" : "application/pdf".equals(mime) ? ".pdf" : ".bin";
        return "so7o-download-" + System.currentTimeMillis() + ext;
    }

    private void toastOnUi(final String text) {
        runOnUiThread(new Runnable() {
            @Override
            public void run() {
                Toast.makeText(MainActivity.this, text, Toast.LENGTH_LONG).show();
            }
        });
    }

    // ----------------------------------------------------------------- bridge

    /** In-app channel (page -> Java), independent of CDP. */
    public class Bridge {
        @JavascriptInterface
        public String ping() {
            return "pong from app pid " + android.os.Process.myPid()
                    + " at " + System.currentTimeMillis();
        }

        /** Introspection: which socket should an outside client aim at? */
        @JavascriptInterface
        public String info() {
            int pid = android.os.Process.myPid();
            return "{\"pid\":" + pid
                    + ",\"socket\":\"webview_devtools_remote_" + pid
                    + "\",\"relay\":\"127.0.0.1:" + RelayServer.PORT
                    + "\",\"uptime_ms\":" + android.os.SystemClock.elapsedRealtime() + "}";
        }

        /** Prove that a CDP call really crossed into the Android layer. */
        @JavascriptInterface
        public String toast(final String text) {
            toastOnUi(text);
            return "toasted: " + text;
        }

        /**
         * Save a data: URL (a blob the page owns) into Downloads. This is how
         * blob: "download" links get out of the renderer.
         */
        @JavascriptInterface
        public String saveDataUrl(String name, String dataUrl) {
            try {
                int comma = dataUrl.indexOf(',');
                if (comma < 0) return "error: not a data URL";
                String head = dataUrl.substring(0, comma);
                String body = dataUrl.substring(comma + 1);
                int semi = head.indexOf(';');
                String mime = head.length() > 5 ? head.substring(5, semi < 0 ? head.length() : semi) : "application/octet-stream";
                byte[] bytes = head.contains(";base64")
                        ? Base64.decode(body, Base64.DEFAULT)
                        : java.net.URLDecoder.decode(body, "UTF-8").getBytes(StandardCharsets.UTF_8);
                java.io.ByteArrayInputStream in = new java.io.ByteArrayInputStream(bytes);
                Uri saved = save(name, mime, in);
                Log.i(TAG, "saveDataUrl " + name + " -> " + saved);
                toastOnUi("saved to Downloads/" + name);
                return "saved: " + name + " (" + bytes.length + "B)";
            } catch (Exception e) {
                Log.w(TAG, "saveDataUrl failed", e);
                return "error: " + e;
            }
        }

        /** Observability: what the last <input type=file> asked for. */
        @JavascriptInterface
        public String lastFileChooser() {
            return lastFileChooser;
        }

        /**
         * Why a capture may be refused. The interesting split is permission vs
         * app-op: checkSelfPermission() can say granted while AudioRecord()/
         * CameraManager() look at the *app-op* and fail anyway.
         */
        @JavascriptInterface
        public String diagnostics() {
            try {
                AppOpsManager ops = (AppOpsManager) getSystemService(APP_OPS_SERVICE);
                AudioManager am = (AudioManager) getSystemService(AUDIO_SERVICE);
                PackageManager pm = getPackageManager();
                int uid = android.os.Process.myUid();
                String pkg = getPackageName();
                return "{" + "\"sdk\":" + android.os.Build.VERSION.SDK_INT
                        + ",\"targetSdk\":" + pm.getApplicationInfo(pkg, 0).targetSdkVersion
                        + ",\"cameraPermission\":" + (checkSelfPermission(Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED)
                        + ",\"micPermission\":" + (checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED)
                        + ",\"micAppOp\":\"" + opName(ops.unsafeCheckOpNoThrow(AppOpsManager.OPSTR_RECORD_AUDIO, uid, pkg)) + "\""
                        + ",\"cameraAppOp\":\"" + opName(ops.unsafeCheckOpNoThrow(AppOpsManager.OPSTR_CAMERA, uid, pkg)) + "\""
                        + ",\"audioMode\":" + am.getMode()
                        + ",\"micMute\":" + am.isMicrophoneMute()
                        + ",\"hasMic\":" + pm.hasSystemFeature(PackageManager.FEATURE_MICROPHONE)
                        + ",\"nativeSampleRate\":" + am.getProperty(AudioManager.PROPERTY_OUTPUT_SAMPLE_RATE)
                        + ",\"windowFocus\":" + windowFocused()
                        + "}";
            } catch (Exception e) {
                Log.w(TAG, "diagnostics failed", e);
                return "{\"error\":\"" + e + "\"}";
            }
        }
    }

    private boolean windowFocused() {
        return web != null && web.hasWindowFocus();
    }

    private static String opName(int mode) {
        if (mode == AppOpsManager.MODE_ALLOWED) return "allowed";
        if (mode == AppOpsManager.MODE_IGNORED) return "IGNORED";
        if (mode == AppOpsManager.MODE_ERRORED) return "ERRORED";
        if (mode == AppOpsManager.MODE_DEFAULT) return "default";
        return "mode" + mode;
    }

    // ------------------------------------------------------------ lifecycle

    @Override
    public void onRequestPermissionsResult(int code, String[] permissions, int[] results) {
        if (code == REQ_MEDIA && pendingMediaRequest != null) {
            boolean granted = permissions.length > 0;
            for (int r : results) granted = granted && r == PackageManager.PERMISSION_GRANTED;
            Log.i(TAG, "runtime media permission(s) " + (granted ? "granted" : "denied"));
            if (granted) pendingMediaRequest.grant(pendingMediaResources);
            else pendingMediaRequest.deny();
            pendingMediaRequest = null;
            pendingMediaResources = null;
            return;
        }
        super.onRequestPermissionsResult(code, permissions, results);
    }

    @Override
    protected void onActivityResult(int code, int result, Intent data) {
        if (code == REQ_FILE) {
            ValueCallback<Uri[]> callback = filePathCallback;
            filePathCallback = null;
            if (callback == null) return;
            Uri[] uris = null;
            if (result == RESULT_OK) {
                if (data == null || (data.getData() == null && data.getClipData() == null)) {
                    // the camera wrote into the MediaStore entry we contributed
                    if (captureOutputUri != null) uris = new Uri[] { captureOutputUri };
                } else if (data.getClipData() != null) {
                    ClipData clip = data.getClipData();
                    uris = new Uri[clip.getItemCount()];
                    for (int i = 0; i < clip.getItemCount(); i++) uris[i] = clip.getItemAt(i).getUri();
                } else {
                    uris = new Uri[] { data.getData() };
                }
            }
            Log.i(TAG, "file chooser result: " + (uris == null ? "cancelled" : java.util.Arrays.toString(uris)));
            callback.onReceiveValue(uris); // null on cancel, or the page's input stays stuck
            captureOutputUri = null;
            return;
        }
        super.onActivityResult(code, result, data);
    }

    private static String[] resourcesFor(boolean video, boolean audio) {
        String[] out = new String[(video ? 1 : 0) + (audio ? 1 : 0)];
        int i = 0;
        if (video) out[i++] = PermissionRequest.RESOURCE_VIDEO_CAPTURE;
        if (audio) out[i] = PermissionRequest.RESOURCE_AUDIO_CAPTURE;
        return out;
    }

    @Override
    public void onBackPressed() {
        if (popup != null) {          // close a window.open() popup first
            popup.dismiss();
            return;
        }
        if (web != null && web.canGoBack()) {
            web.goBack();
        } else {
            super.onBackPressed();
        }
    }

    // ------------------------------------------------------------- utilities

    private static String pickType(String[] accept) {
        if (accept == null) return "*/*";
        for (String a : accept) {
            if (a == null || a.isEmpty()) continue;
            if (a.startsWith(".")) return "*/*";          // an extension, not a mime type
            if (a.endsWith("/*")) return a;
            int slash = a.indexOf('/');
            if (slash > 0) return a.substring(0, slash) + "/*";
        }
        return "*/*";
    }

    private static String jsonString(String s) {
        if (s == null) return "null";
        StringBuilder b = new StringBuilder("\"");
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            if (c == '"' || c == '\\') b.append('\\').append(c);
            else if (c == '\n') b.append("\\n");
            else if (c == '\r') b.append("\\r");
            else if (c < 0x20) b.append(String.format("\\u%04x", (int) c));
            else b.append(c);
        }
        return b.append('"').toString();
    }

    private static String jsonStrings(String[] items) {
        if (items == null) return "[]";
        StringBuilder b = new StringBuilder("[");
        for (int i = 0; i < items.length; i++) {
            if (i > 0) b.append(',');
            b.append(jsonString(items[i]));
        }
        return b.append(']').toString();
    }
}
