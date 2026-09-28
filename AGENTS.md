# AGENTS.md — So7o Android Webview Shell

## What this is

A single-Activity Android app that hosts a **WebView whose Chrome DevTools Protocol
socket is reachable from Termux**, plus the Termux-side tooling to drive it.
Built on-device with a **hand-rolled build** (`build.sh`) — **no Gradle, no Android
SDK package, no Kotlin**; the app is plain Java.

Its purpose is to be an **agent/harness WebView for Android browser automation**, and the
common use case is **mobile browser testing**: a real WebView at a real phone viewport, real
touch input and real pixels, driven over CDP by whichever client you like. Any change should
keep that path — attach, drive, capture — the thing that works.

## Workflow — branches, protection, releases

The repo is **`jan5o7o/android-webview-cdp`** (renamed from `webview-shell`; GitHub redirects the
old URL). **`dev` is the default branch.**

| Branch | Role | Guarded by |
|---|---|---|
| `main` | releases only — what strangers clone | ruleset *main: releases only* |
| `dev` | integration; all work lands here | ruleset *dev: integration* |
| `feat/*` `fix/*` `docs/*` | short-lived, PR into `dev` | — |

- **`main` requires a pull request**, forbids deletion and force-push, and requires linear history.
  Nobody — human or agent — commits to `main` directly; GitHub rejects the push.
- **`dev`** forbids deletion and force-push. The repository-admin role may bypass, so the owner can
  still push directly when moving fast.
- **Agents: branch off `dev`, never `main`.** Run `git fetch origin && git rebase origin/dev`
  before pushing — the remote is shared and a plain push is often rejected.

### Releases

1. Bump `versionCode` / `versionName` in `AndroidManifest.xml` — they are the source of truth
   (currently `4` / `0.4`).
2. PR `dev` → `main` (the ruleset requires the PR), merge.
3. `git tag -a v0.1.0 -m "…" && git push origin v0.1.0`, tagged on `main`.
4. `gh release create v0.1.0 out/so7o-webview.apk --title … --notes …` — attach the signed APK.
5. **Re-align `dev`.** A rebase or squash merge mints a *new* commit, so `main` and `dev` diverge
   by SHA even though the trees are identical. Check for **content** that has not shipped, then
   point `dev` back at the release:

   ```bash
   git fetch origin
   git diff --quiet origin/main dev || { git diff --stat origin/main dev; echo "dev has unshipped content — stop"; }
   git checkout dev && git reset --hard origin/main
   git push --force-with-lease origin dev
   ```

   Compare content, **not** `git log origin/main..dev`: a rebase merge rewrites the SHA, so the
   commit that *is* on `main` still appears there — the check never goes quiet, which trains you
   to ignore it. (This cost a discarded commit once: the reset ran with two commits listed.)
   `dev` carries no PR requirement and the admin role bypasses `non_fast_forward`, so the
   force-push is allowed.

### Conventions this repo has already learned the hard way

- **Quote output as measured.** The README's transcripts are either re-recorded against the
  current build or explicitly labelled as past runs. Do not retro-edit a historical transcript to
  match a rename: saying "this is a slightly edited record" is honest, silently rewriting one is
  not. When a rename touches a *regex-escaped* form of a package name (e.g. `dev\.so7o\.webview`),
  a plain string sweep will miss it — grep for the escaped form too.
- **Keep `## Verification status` honest.** Move a row up only after re-testing it on a device,
  and say when a row predates a change that would invalidate it.
- **A gate is not implemented until the *default refusal* is answered.** A bare WebView denies
  `onPermissionRequest`, ignores `<input type=file>`, drops `DownloadListener` targets, replaces
  the view on `window.open`, and swallows JS dialogs — all silently, with no error the page can
  read. The README's [gates table](../README.md#gates-a-bare-webview-refuses) lists what this app
  answers and what it does not. Microphone capture is the current open item: implemented, grant
  path verified, and refused by the device (`NotReadableError`) with permission and app-op both
  `allowed` — do not paper over it when adding rows to `## Verified`.

## Picking the work back up

Nothing here is remembered between sessions, so this is the shortest path from a cold start:

```bash
bash ./setup.sh --pre-install-checkup   # read-only; says exactly what is missing
```

**The only step that needs a human** is adb — Developer options → Wireless debugging → *pair with
a code*. Its gotchas bite every single time:

- The **pairing port and the connect port differ**, and both rotate.
- `adb pair` against a connect port fails with `protocol fault (couldn't read status message)`.
- `adb connect` at a port that answers but is not adbd leaves an **`offline` transport** rather
  than an error — clear it with `adb kill-server` or `adb disconnect <addr>`.
- **`adb mdns services` does not work** with Termux's `android-tools` build; scan the loopback
  ephemeral range for the listening port instead.
- The phone's IP **changes between sessions**; because Termux runs *on* the phone,
  `127.0.0.1:<port>` sidesteps the churn entirely.

Then:

```bash
bash ./setup.sh          # build + install + verify (needs adb)
./display.sh overlay     # phone-sized and off-screen (needs adb)
node cdp.mjs --repl      # once installed, driving it needs NO adb at all
```

Because the relay lives on `127.0.0.1:9334`, **driving survives a lost adb session** — only
install, uninstall and the display work do not. If adb is gone and the app is stopped,
`am start -n app.so7o.webview/.MainActivity` (termux-am, no adb) brings it and the relay back.

## Build & install

On a new machine, run the read-only checkup first — it prints what is missing and the exact
command to fix each item, and writes nothing:

```bash
bash ./setup.sh --pre-install-checkup    # pre-install checkup (no changes)
bash ./setup.sh                          # then: install pkgs, build, install, verify
```

By hand, the same thing is:

```bash
./build.sh                       # aapt2 -> javac -> d8 -> alignment check -> apksigner
adb install -r out/so7o-webview.apk
adb shell am start -n app.so7o.webview/.MainActivity            # optionally --display <id>
```

Signing needs the keystore password, which is **deliberately not in the repo**: set `KSPASS` in
the environment, or keep it in `~/.so7o-webview-kspass`. `build.sh` fails closed when neither is
present (and does so before it removes `build/`/`out/`).

`build.sh` needs `sdk/platforms/android-36/android.jar` (27 MB, not in the repo — `setup.sh`
fetches it). `keystore.jks` (signing key), `out/`, `build/` are gitignored.

Everything needed before this is in the README's *Prerequisites — setting up a fresh Android
device*: Termux package list (`aapt2 d8 apksigner openjdk-21 android-tools nodejs-lts python3
zip unzip curl` — **`zip` is easy to miss and `build.sh` needs it to add `classes.dex`**),
the platform jar, and wireless-ADB pairing.

Two traps for a fresh checkout:

- **No signing key is committed.** `build.sh` generates `keystore.jks` on first use, so a fresh
  clone signs with a new key and Android will refuse to update an app installed from someone
  else's build: `adb uninstall app.so7o.webview` first (`INSTALL_FAILED_UPDATE_INCOMPATIBLE`
  otherwise).
- **Off-device (laptop + USB phone):** run the scripts as `bash build.sh` — their shebangs are
  absolute Termux paths — and reach the relay with `adb forward tcp:9334 tcp:9334`, which
  forwards to the device's loopback where the relay listens.

## Architecture

| File | Role |
|---|---|
| `java/.../MainActivity.java` | debug flag, WebView, `so7o` JS bridge (`ping`/`info`/`toast`) |
| `java/.../RelayServer.java` | byte-pumps the app's own DevTools socket to `127.0.0.1:9334` |
| `java/.../KeepAliveService.java` | `specialUse` foreground service — keeps the process out of the frozen cgroup |
| `assets/index.html` | demo page; exposes `window.__so7o` as a stable CDP handle |
| `build.sh` | the hand-rolled build pipeline |
| `cdp-webview.sh` | `up` / `direct` / `status` / `info` / `down` |
| `cdp.mjs` | dependency-free CDP client (Node 22+ global `WebSocket`), incl. `--device` profiles |
| `display.sh` | runs the app on a simulated phone-sized secondary display, off-screen |
### Two mechanisms worth understanding before changing anything

1. **Why adb, and why a relay.** The DevTools server listens on the abstract unix
   socket `webview_devtools_remote_<pid>`. SELinux blocks one app from connecting to
   another app's socket (Termux gets `EACCES`), and the shell UID — i.e. Shizuku — is
   refused too. `adbd` is allowed, hence `adb forward`. A process *may* connect to an
   abstract socket **it created itself**, which is what makes `RelayServer` possible —
   and why that relay has to live inside the WebView's process, not outside it.
2. **Why the foreground service exists.** A backgrounded app is put in the frozen
   cgroup: the process stays alive and `/proc/net/unix` still lists the socket, but it
   is never accepted, so CDP clients *hang* rather than failing. `KeepAliveService`
   makes the process freeze-exempt. `cdp-webview.sh up` also `am start`s, which
   unfreezes an already-parked app.

## Conventions

- **Java 8 syntax**, no lambdas (d8 desugaring risk) — anonymous classes.
- No third-party dependencies; the CDP client uses Node's built-in `WebSocket`.
- Ports: **9333** = `adb forward`, **9334** = in-app relay, **9222/9223** = Chrome
  (someone else's — do not take them). Both 9333 and 9334 bind the *same* device
  loopback, so they can never be the same port.

## Displays

`display.sh overlay [WxH@DPI]` writes the `overlay_display_devices` global setting (shell holds
`WRITE_SECURE_SETTINGS`, so adb suffices), which makes system_server create a simulated
secondary display. Phone-sized by construction — 1080×2340/420 gives the shell 411×851 CSS px
at dpr 2.625 — and it renders off-screen at native resolution. No root, no Shizuku, no
accessibility service, no other app.

Six things that will bite:

- **`settings put global overlay_display_devices ""` fails** (`Bad arguments`). Clear with
  `settings delete global overlay_display_devices` — what `overlay-off` runs. The setting
  persists, so the display returns after a reboot until deleted.
- **The setting wants `WxH/DPI`, not `WxH@DPI`.** Normalise before writing it, or you write
  `2340/420` as the height and nothing is created.
- **Force-stop before launching onto the display.** `am start --display N` on a running
  activity *moves* the task: it keeps the old window size and carries the previous display's
  density, so you get 480×993 CSS at dpr 2.25 instead of 411×851 at 2.625. Launch fresh, then
  `am task resize <taskId> 0 0 <w> <h>`.
- **Screenshots need a surface.** The window must be on a display that is ON and *has a render
  target*. A surface-less display (headless, `state=OFF`) produces no frames by any route — all
  four capture APIs fail (`captureScreenshot` default / `fromSurface:false` /
  `captureBeyondViewport:true` time out, `startScreencast` yields 0 frames) — and a `hidden`
  page behaves the same way. JS, DOM, network, timers and CDP input injection still work there,
  so a surface-less display is for logic/DOM/network assertions only.
  `overlay_display_devices` always renders, so this path always has pixels.
- **Window sizing, not the display, is the device-specific part.** This device ships freeform
  window management, so a task on a secondary display can arrive small and *keeps its bounds*
  when it moves displays — which is why `overlay` force-stops and then resizes unconditionally.
  On a non-DeX phone expect fullscreen and a no-op resize; `--windowingMode 1` is the knob if a
  device does not fill. (Inferred — never measured on a non-DeX device.)
- **`screencap` cannot see simulated displays** — `-a` lists only physical ones, `-d` takes
  the SurfaceFlinger token and rejects a virtual display's. Capture with CDP `--shot`.

### Stopping

- `display.sh overlay-off` / `display.sh none` close the displays; `cdp-webview.sh down`
  removes the adb forward. **None of them stop the app.**
- **A dead Activity with a live process is expected**: `KeepAliveService` outlives the
  Activity, so the FGS notification stays and the relay keeps listening on 9334. `status`
  showing `relay UP` with an empty `app display` is correct, not a bug — don't "fix" it by
  tying the relay to the Activity lifecycle.
- Only `adb shell am force-stop app.so7o.webview` stops everything (process, notification, port).

## Known behaviours / gotchas

- `aapt2 link` needs `-A assets`, or the HTML silently isn't in the APK.
- The devtools server keeps **a target per WebView ever created**; after Activity
  recreations `/json/list` shows several identical pages. Never pick `list[0]` — probe
  for the target whose `document.visibilityState` is `visible` (what `cdp.mjs` does).
- The relay is **bind-once per process** (static flag) — Activity recreation re-runs
  `onCreate` and a second bind would fail with `EADDRINUSE`.
- A backgrounded app cannot show a Toast (Android 11+).
- `Target.createTarget` / `/json/new` are blocked on Android; attach to an existing target.
- **Emulated device pixels must fit the display surface.** Beyond it,
  `captureScreenshot` returns the requested size with the page drawn twice.
  `cdp.mjs` clamps the scale factor to 3 / 2.625 / 2 / 1.5 / 1 accordingly, so size the
  display to the device you are testing when you need native-resolution captures.

## Verification status

Confirmed on SM-F936B, One UI, Android 16 / API 36. Keep this honest — do not move
rows up without re-testing.

**Verified:** socket name; `/json/version` package identity; `Runtime.evaluate`;
`Input.dispatchMouseEvent`/`insertText`/`dispatchKeyEvent`; `Page.navigate` to external
sites; `Network.*` events; `Page.captureScreenshot`; relay on 9334 with an empty
`adb forward` table; the Java bridge crossing (`so7o.info()` matched `pidof`); running on
display 17 (XREAL) and an `overlay_display_devices` simulated display (411x851 CSS @2.625,
native 1082x2237 captures, and a full-retina 1170x2532 when the display is sized 1200x2700).
A real network site is navigated and asserted as part of `setup.sh`'s verification.

**Not verified:** multiple simultaneous CDP clients on one target; a WebSocket held open
for hours through the relay; a WebView in a `TYPE_ACCESSIBILITY_OVERLAY` window.
