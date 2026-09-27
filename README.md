# So7o Android Webview Shell

[![CI](https://github.com/jan5o7o/android-webview-cdp/actions/workflows/ci.yml/badge.svg)](https://github.com/jan5o7o/android-webview-cdp/actions/workflows/ci.yml)

A 20 KB single-Activity Android app that hosts a **WebView you can drive over the
Chrome DevTools Protocol from Termux** — plus the Termux-side tooling to do it.
Built on-device, no Gradle, no Android SDK — a hand-rolled `build.sh`
(aapt2 → javac → d8 → apksigner).

**What it is for:** an agent/harness WebView for **browser automation on Android**. The common
case is **mobile browser testing** — you get a real WebView, a real phone viewport, real touch
input and real pixels, with no desktop emulator and no Chrome-for-Android plumbing in the loop.
Any CDP client can drive it; `cdp.mjs` and Puppeteer are both verified below.

Source lives at `github.com/jan5o7o/android-webview-cdp`.

Verified end-to-end on SM-F936B (One UI, Android 16 / API 36), 2026-09.

> **On the recorded output below.** Two kinds are mixed, and each says which it is. The
> `## How it works` walkthrough was re-recorded on `app.so7o.webview` as it stands now — those
> numbers are current. The `## A real run` transcript is a *past* run from before the rename,
> kept as it happened, so it still reads `Pi WebView Shell` / `com.pi.webview` and still checks
> `pi.dev`. The screenshots were re-captured on `app.so7o.webview`, and the [Verified](#verified)
> banner records exactly what was re-run.

## Quick start

Termux on the phone, Android 14+ — [*Prerequisites*](#prerequisites-a-fresh-android-device)
is the long version:

```bash
gh repo clone jan5o7o/android-webview-cdp && cd android-webview-cdp
bash ./setup.sh --pre-install-checkup     # read-only: says exactly what to fix, if anything
bash ./setup.sh                           # installs, builds, installs, launches, verifies
node cdp.mjs --repl                       # drive the page
```

To run it off the phone screen instead, at a phone-sized viewport:

```bash
./display.sh overlay                      # a simulated 1080x2340 display, rendering off-screen
node cdp.mjs --shot shot.png              # 1082x2237
```

One thing cannot be scripted: the adb connection (Developer options → Wireless debugging →
*pair with a code*). After that the flow is automatic — and once the app is running, **nothing
needs adb at all**, because the app serves CDP on `127.0.0.1:9334` itself.

## How it works

```
Termux (node / python / curl)                     the app process (pid N)
  │                                                     │
  │ HTTP + WS on 127.0.0.1:9333                         │  WebView DevTools server
  ▼                                                     ▼
adb server (running INSIDE Termux) ── adb forward ──► @webview_devtools_remote_N
```

`WebView.setWebContentsDebuggingEnabled(true)` makes WebView expose CDP on an
**abstract unix socket** named `webview_devtools_remote_<pid>`.

You cannot connect to that socket from Termux directly: SELinux blocks one app
from connecting to another app's socket (`EACCES`), and the shell UID (i.e.
Shizuku) is refused too. `adbd` *is* allowed, so `adb forward` is the way in —
and because Termux's own adb server runs on the device, the forwarded port lands
on the **device's own loopback**.

That is the transport. What it buys you, end to end, is a page you fully control from a
shell — and none of it except the `adb forward` path needs adb. The run below is a real one:
SM-F936B, Android 16, Termux on the phone. Every command goes over the in-app relay on 9334 —
`adb forward --list` is empty and none of these invoke adb, even though adb happened to be
connected while they were recorded.

The first check is what is on the other end of the port:

```console
$ curl -s 127.0.0.1:9334/json/version
{
   "Android-Package": "app.so7o.webview",
   "Browser": "Chrome/153.0.8010.36",
   "Protocol-Version": "1.3",
   "User-Agent": "Mozilla/5.0 (Linux; Android 16; SM-F936B …; wv) …",
   "webSocketDebuggerUrl": "ws://127.0.0.1:9334/devtools/browser"
}
```

Then the page itself. `Runtime.evaluate` returns the page's own view of its world — plus data
only the Java side can know, which is the part that proves the bridge:

```console
$ node cdp.mjs 'JSON.stringify({url:location.href, viewport:innerWidth+"x"+innerHeight,
    dpr:devicePixelRatio, ping:so7o.ping(), info:so7o.info()})'
{"url":"file:///android_asset/index.html","viewport":"805x927","dpr":2.25,
 "ping":"pong from app pid 1832 at 1790515039819",
 "info":"{\"pid\":1832,\"socket\":\"webview_devtools_remote_1832\",…}"}
```

`so7o.info()` is a `@JavascriptInterface` method, so `pid 1832` came out of `Process.myPid()` on
the Java side and made the round trip JS → Java → CDP → Termux. `805x927` at dpr 2.25 is this
device's unfolded inner screen (the window is freeform, so it is a little shorter than the full
screen).

Input is *injected*, not faked in JS: `--click` dispatches a real mouse event at the element's
box, and `--type` an `Input.insertText`, so the page cannot tell either from a finger.

```console
$ node cdp.mjs --click 'text=tap me'
clicked BUTTON at 160,432
$ node cdp.mjs --type 'typed by CDP from Termux'
typed "typed by CDP from Termux"
```

The bridge runs the other direction too — page JS reaching Android:

```console
$ node cdp.mjs 'so7o.toast("Hello from CDP — sent by node in Termux")'
toasted: Hello from CDP — sent by node in Termux
```

And a real network site, fetched by the shell's own WebView rather than curl:

```console
$ node cdp.mjs --nav https://example.com
navigated -> https://example.com/
$ node cdp.mjs 'document.querySelector("h1").textContent'
Example Domain
```

Device emulation rewrites the viewport and UA — and refuses to pretend when the display's
pixel surface is smaller than what you asked for:

```console
$ node cdp.mjs --device pixel-7 --shot pixel7.png
! display surface is only 1814x2178 px, but 412x915 CSS @2.625x needs 1082x2402 px.
  clamping dsf 2.625 -> 2 (→ 824x1830 px); beyond the surface, screenshots repeat the page.
  override with --no-clamp, or --metrics 412x915x2 to pin this deliberately.
device: pixel-7 -> {"w":412,"h":915,"dpr":2.000000014901161}  (surface 1814x2178)
screenshot -> pixel7.png
```

`--shot` is `Page.captureScreenshot`, so `pixel7.png` holds the page's own pixels, not a phone
screenshot. Events arrive on the same socket, and `--repl` puts all of it behind a prompt (which
also takes piped input, so a REPL session can be scripted):

```console
$ DEBUG=1 node cdp.mjs 'console.log("hello from the page")'
target 64260D29F27A7FCE9867A134AA1FA430 — So7o Android Webview Shell — file:///android_asset/index.html
  [event] Runtime.executionContextCreated
  [log] "hello from the page"
undefined

$ printf '1+1\nlocation.href\n' | node cdp.mjs --repl
CDP repl — So7o Android Webview Shell; .help for commands, .exit to leave
cdp> 2
file:///android_asset/index.html
```

**What this path cannot do is put the app somewhere better.** `./display.sh overlay` writes the
`overlay_display_devices` global, which needs the shell's `WRITE_SECURE_SETTINGS` — adb only. It
exits 1 on a device with no adb (`adb: no devices/emulators found`) while the relay keeps
serving. Every step above is adb-free; that one is not.

## Screenshots

All of these are produced **by the tool itself** — `node cdp.mjs --shot`, i.e. the same
`Page.captureScreenshot` path documented below, not a phone screenshot. The demo-page captures
are current, taken on `app.so7o.webview`; the external-page ones are from earlier runs against
other display setups.

**The shell on a simulated display** — `./display.sh overlay` puts it on a 1080×2340/420
`overlay_display_devices` display that renders off-screen. 411×851 CSS px at dpr 2.625, captured
at the display's native 1082×2237:

![So7o Android Webview Shell on a simulated 1080x2340 phone display](docs/img/shell-on-display.png)

**The same shell at its window's native size** (840×1326 device px), when it is *not* on a
simulated display — the bundled demo page with the Java bridge answering:

![So7o Android Webview Shell showing the bundled demo page](docs/img/shell-window.png)

**The same page under `--device pixel-7`** — the page lays out at 412×915 CSS px with touch and a
mobile UA. The scale factor is 1.25 here, picked so the emulated pixels fit the window surface
(see *Phone-sized viewports*); 515×1144:

![The demo page laid out at a Pixel 7 viewport](docs/img/phone-viewport-pixel7.png)

**A real site at `--device iphone-14`** — 390×844 CSS px, driven and captured over the relay
with no adb forward:

![example.com rendered at an iPhone 14 viewport](docs/img/example-com-iphone-14.png)

**No emulation at all** — example.com in the shell on a simulated phone display
(`./display.sh overlay`), captured at the display's native 1082×2237:

![example.com on a simulated 1080x2340 phone display, captured at native size](docs/img/native-phone-display.png)

**A real network site at a real phone viewport** — Hacker News at 412×915 CSS px, which is what
`setup.sh` asserts as part of verification. Captured at 618×1373, the scale factor clamped to 1.5
so the emulated pixels fit the window surface (see *Phone-sized viewports*):

![Hacker News front page at a phone viewport](docs/img/hn-phone-viewport.png)

## Prerequisites: a fresh Android device

### What `setup.sh` does — and won't do

Commands are in [Quick start](#quick-start). `setup.sh` is idempotent and covers the traps a fresh
machine hits: missing Termux packages (including **`zip`**, a separate package from `unzip` and
easy to miss), the 27 MB platform jar that is deliberately not in the repo, a missing signing
password, and the signature clash from a fresh checkout (no signing key is committed, so it
uninstalls the old copy and reinstalls). It ends with an unambiguous verdict, and in checkup mode
it writes nothing at all.

Run it as `bash ./setup.sh` — the shebang is a Termux absolute path, so that form also keeps
working if you are on a laptop with a USB phone.

> **See it done for real:** [*A real run, start to finish*](#a-real-run-start-to-finish) — the
> parts that went wrong and why.

**What it cannot do** (it says so, and tells you who can):

| not scriptable | why |
|---|---|
| install Termux | you are reading this from Termux; it is the one hard prerequisite |
| enable Developer options / Wireless debugging | Settings UI only |
| `adb pair` the device | one-time, needs the pairing code on screen |

### The device

- **Android 14+ (API 34+).** `build.sh` declares `minSdk 30`, but the keep-alive service
  uses `foregroundServiceType="specialUse"`, which only exists from API 34 — treat 14 as the
  real floor. Verified on Android 16 / One UI (SM-F936B); **not tested on anything older.**
- **A current WebView provider** (Chrome, or Google's standalone WebView). The CDP version
  you get comes from it — this device reports `Chrome/153`, protocol 1.3.
- Nothing else. No root, no Shizuku, no accessibility service. The relay means you never even
  need adb *after launch*.

### Termux — which build, and what it must have

**Which build.** [F-Droid](https://f-droid.org/packages/com.termux/) or the
[GitHub releases](https://github.com/termux/termux-app/releases). **Not the Play Store build:**
it is deprecated, its package repository is not the one these packages come from, and it cannot be
upgraded in place — uninstall it first if you have it. The tell is `pkg` itself: if `pkg update`
complains or `pkg install aapt2` finds nothing, that is the build you are on.

**What it must have.** Nothing. No add-on apps, no permissions, no root:

| commonly installed | needed? | why |
|---|---|---|
| Termux:API, Termux:Boot, Termux:Widget | **no** | no `termux-*` command is used. `setup.sh` checks that `termux-setup-storage` *exists*, only to confirm it is running in Termux — it never runs it, so you are never asked for storage access |
| storage permission | **no** | nothing outside the repo and `$HOME` is written; the platform jar unpacks into `sdk/` |
| root, `sudo`, proot-distro, X11 | **no** | the build is a plain userspace toolchain |
| a particular Termux version | **no** | any current build provides bash 5 and the packages below |

Two floors worth not confusing: Termux itself supports considerably older Android than this app
requires, so *having Termux* tells you nothing about the **Android 14+** device requirement above.

**Where it all runs.** Everything — the build, adb, the CDP client — runs *inside Termux on the
phone*, including Termux's own **adb server**. That is what makes the `127.0.0.1:<port>` shortcuts
work, and why killing Termux takes the adb connection and any forwards with it.

### Packages

```bash
pkg update && pkg upgrade
pkg install aapt2 d8 apksigner openjdk-21 python3 zip android-tools nodejs-lts unzip curl
```

Split by what actually needs them — the second group is only needed to *drive* it:

| needed for | package | provides |
|---|---|---|
| **the build**: `./build.sh` | `aapt2` | resource + manifest compiler |
| | `d8` | dexer |
| | `apksigner` | signing |
| | `openjdk-21` | `javac` and `keytool` (21.0.12 here) |
| | `zip` | packaging — `build.sh` adds `classes.dex` with `zip`, a *separate* package from `unzip` |
| | `python3` | the alignment check inside `build.sh` — build-critical, not a helper |
| **installing and driving** | `android-tools` | `adb` 1.0.41 / 35.0.2 |
| | `nodejs-lts` | `node` — needs **22+** for the built-in `WebSocket` that `cdp.mjs` uses |
| | `curl` | the relay/HTTP checks in the scripts |
| | `unzip` | extracting the platform jar |

`aidl` is **not** needed here.

### The platform jar (27 MB, not in this repo)

```bash
curl -LO https://dl.google.com/android/repository/platform-36_r02.zip   # HTTP 200, verified
unzip -j platform-36_r02.zip android-36/android.jar -d sdk/platforms/android-36/
```

Sanity check: that jar is ~27,768,000 bytes. `build.sh` looks for it at
`sdk/platforms/android-36/android.jar`.

### Wireless ADB, from Termux on the same device

Because Termux runs *on* the phone, its **adb server runs inside Termux** — which is why
`adb forward` lands on the device's own loopback and every CDP path here is `127.0.0.1`.

1. Settings → About phone → tap **Build number** 7× → Developer options.
2. **Wireless debugging** → on → *Pair device with pairing code*; note the IP:port **and the code**.
3. `adb pair 192.168.x.y:<pair-port>` — asks for the code; once per device.
4. `adb connect 192.168.x.y:<connect-port>` — the port shown on the Wireless debugging screen,
   which **changes every time you toggle it**.

Notes worth having in advance:
- On the same device, `adb connect 127.0.0.1:<port>` also works (verified) — no IP needed.
- `adb mdns services` does **not** work with Termux's `android-tools` build
  (`error: unknown host service 'mdns:services'`). Read the port off the screen, or discover
  it over mDNS (`_adb-tls-connect._tcp`) with any zeroconf client.
- Transports are ambiguous with more than one connection — use `adb -s <host:port>`.

### First run: the three things that surprise people

Commands are in [*Use*](#use); this is what actually needs explaining.

**1. A fresh clone signs with a different key.** There is deliberately **no signing key in this
repo** — `build.sh` generates `keystore.jks` on first use — so Android refuses to replace an app
installed from someone else's build:

```bash
adb uninstall app.so7o.webview        # INSTALL_FAILED_UPDATE_INCOMPATIBLE otherwise
```

Uninstalling costs nothing here (the app stores no data).

**2. The keystore password is not in the repo either.** `build.sh` takes it from `KSPASS` in the
environment or from `~/.so7o-webview-kspass`, and **fails closed** when neither is present — before
it deletes anything, so a missing password cannot cost you a build:

```bash
KSPASS=... ./build.sh               # or once:
printf %s 'the-password' > ~/.so7o-webview-kspass && chmod 600 ~/.so7o-webview-kspass
```

A keystore keeps whatever password it was created with, so with an existing `keystore.jks` that
file must hold *that* password rather than a new one.

**3. Android 13+ asks for notification permission.** It belongs to the keep-alive foreground
service — the thing that stops the platform freezing the process (see *The freeze problem*).
`bash ./setup.sh` grants it for you.

### Verifying it worked

Each step has an unambiguous check — useful when an agent is driving:

| step | check | expected |
|---|---|---|
| build | `ls -l out/so7o-webview.apk` | ~20 KB file |
| installed | `adb shell pm list packages \| grep app.so7o.webview` | `package:app.so7o.webview` |
| running | `adb shell pidof app.so7o.webview` | a pid |
| relay | `./cdp-webview.sh direct` | `relay UP on 127.0.0.1:9334` |
| CDP | `node cdp.mjs 'document.title'` | `So7o Android Webview Shell` |
| input | `node cdp.mjs --click 'text=tap me'` then `node cdp.mjs '__so7o.taps()'` | counter +1 |
| real site | `node cdp.mjs --nav https://news.ycombinator.com/news --wait '.titleline' 'document.title'` | `Hacker News` |
| capture | `node cdp.mjs --shot shot.png` | PNG written, non-zero |
| off-screen | `./display.sh overlay` | a display id and `411x851` CSS |

### If the agent is not running in Termux on the phone

Everything is designed for Termux-on-device, but an agent on a laptop with a USB phone works
with two adjustments:

- **Invoke the scripts as `bash build.sh`.** Their shebangs are absolute Termux paths
  (`#!/data/data/com.termux/files/usr/bin/bash`), which do not exist on a laptop.
- **Reach the relay with a TCP forward**: `adb forward tcp:9334 tcp:9334`. That forwards to the
  *device's* loopback, where the relay listens, so the CDP client runs happily on the laptop
  (verified: `curl 127.0.0.1:9444/json/version` through a forward returns this app's
  DevTools handshake). `display.sh overlay` also works from off-device — it is only `adb`
  writing a setting.

Clone with `gh repo clone` or plain `git clone` (a private repo would also need auth).


## Three layers of control

| Layer | Channel | What it can do | Needs |
|---|---|---|---|
| **Transport** | `adb forward tcp:9333 localabstract:…` | reach the socket at all | adb (already connected to itself) |
| **Page** | CDP over the forwarded port | DOM/CSS/JS, real mouse + key input, navigation, network, screenshots, console | nothing in the app |
| **App** | `@JavascriptInterface` bridge (`so7o.*`), driven *through* CDP | anything the Java side exposes: Android APIs, app state | rebuild the app |

CDP is the only layer that needs no app cooperation, which is why it's the useful
one: you can point the same tooling at any WebView/Chrome.

## Use

```bash
cd ~/android-webview-cdp
./build.sh                                  # aapt2 -> javac -> d8 -> alignment -> apksigner
adb install -r out/so7o-webview.apk
adb shell am start -n app.so7o.webview/.MainActivity   # ← starts the relay

node cdp.mjs 'document.title'               # evaluate in the page
node cdp.mjs --click 'button'               # real mouse input (or --click 'text=tap me')
node cdp.mjs --type 'hello'                 # insertText into the focused element
node cdp.mjs --key Enter                    # Enter Tab Escape Backspace Arrow… PageUp/Down
node cdp.mjs --nav https://example.com      # navigate + wait for load
node cdp.mjs --wait '#ready'                # poll for a selector
node cdp.mjs --shot page.png                # screenshot the page
node cdp.mjs --repl                         # interactive: .help .click .nav .shot .exit
node cdp.mjs 'so7o.info()'                    # cross into the Android layer
```

Actions run in a fixed order (`nav → wait → click → type → key → expression → shot`),
so a single invocation can perform a whole sequence. `DEBUG=1` streams CDP events.

**Nothing above touches adb after `am start`.** The app publishes its own DevTools socket on
`127.0.0.1:9334` (`RelayServer`), so the client talks straight to it. The other transport is an
`adb forward`, driven by `./cdp-webview.sh up | direct | status | info | down`, which you need
when you want a port without the app's relay running, or from a laptop — the two are compared in
*Two ways to get a port*.

## Driving it from Puppeteer

`cdp.mjs` is not the only client: the relay is an ordinary CDP endpoint, so anything that speaks
CDP works. **Puppeteer does** — verified against a real, content-dense page rather than a blank
one, at `https://news.ycombinator.com/news`.

Use **`puppeteer-core`**, not `puppeteer`. The full package's install step downloads a *desktop
Linux* Chromium, which will not run on aarch64 Android; `puppeteer-core` ships no browser and
attaches to one that already exists — the WebView. In Termux:

```bash
mkdir -p ~/tmp/pptr-webview && cd ~/tmp/pptr-webview
npm init -y && PUPPETEER_SKIP_DOWNLOAD=1 npm i puppeteer-core
```

```js
import puppeteer from 'puppeteer-core';

const browser = await puppeteer.connect({
  browserURL: 'http://127.0.0.1:9334',   // the relay — no adb
  defaultViewport: null,                  // keep the WebView's real size
});

// Pick the LIVE target: the list accumulates one entry per WebView ever created.
const pages = await browser.pages();
let page;
for (const p of pages)
  if ((await p.evaluate(() => document.visibilityState)) === 'visible') page = p;

await page.goto('https://news.ycombinator.com/news', { waitUntil: 'domcontentloaded' });
await page.$$eval('.titleline > a', (as) => as.slice(0, 5).map((a) => a.textContent.trim()));
await page.click('.titleline > a');        // real Input.dispatchMouseEvent
await page.evaluate(() => so7o.info());      // the Java bridge, same session
await browser.disconnect();
```

What that printed, unedited:

```console
$ node hn.mjs
targets: 4 | attached to visible one
real surface: 480x734@2.25
title      : Hacker News
stories[0:5]:
   1. "As a Language Model": Chat Template Switches LLM Self-Referential Voice
   2. Flip Fluid on Flip Dots
   3. Does Georgism work? Five years later
   4. OpenAI Feared "Optics" of what might appear on Hacker News
   5. Go Concurrency Distilled
story count: 30
rank #1    : 1.
clicked #1 -> https://arxiv.org/abs/2609.25021
back        : https://news.ycombinator.com/news | Hacker News
native shot : 1080x1652
emulated    : 412x915@1.5000000447034836
phone shot  : 618x1373
DONE
```

Reading the DOM, clicking a link for real, navigating back to Hacker News, crossing into Java with
`so7o.info()`, and capturing pixels all work through puppeteer with no app changes. The page at
`412x915 @1.5` (the scale that fits this window):

![Hacker News front page at a phone viewport, driven and captured by puppeteer](docs/img/hn-puppeteer-phone.png)

### What bites, and why

- **`browser.newPage()` cannot work.** It throws `Protocol error (Target.createTarget): Not
  supported` — the same Android restriction that blocks `/json/new`. Attach to the existing page.
- **`pages()[0]` is not necessarily the live page.** The run above saw **4** targets and only one
  reporting `visible`; the rest are leftovers from earlier Activity recreations. Skip the
  visibility probe and you read one page while clicking in another — the same trap `cdp.mjs`
  documents.
- **`connect()`, never `launch()`** — there is no browser to launch, and no Chromium for Termux.
- **Use `disconnect()`, not `close()`.** `close()` sends `Browser.close`; what that does to the
  app's process was not tested here, and the point of attaching is to leave the app alone.
- **Screenshots are unclamped.** Puppeteer sends the emulated size straight to
  `Page.captureScreenshot` without the surface arithmetic `cdp.mjs` does. Ask for more device
  pixels than the WebView's render surface holds and you get an image of the requested size with
  **the page repeated** — measured: `412x915 @2` on the bundled demo page returned 824x1830 with
  the page drawn five times. That is the WebView, not puppeteer: a raw
  `Page.captureScreenshot` with the same override produces an identical file, and a short page
  such as `example.com` hides the repeat because its content ends before the seam. Keep the
  emulated pixels inside the surface (this window holds 1080x1652 device px, so `412x915 @1.5` =
  618x1373 is safe and `@2` = 824x1830 is not), or keep using `cdp.mjs --shot`, which clamps.
- **A backgrounded app hangs CDP** (frozen cgroup) — `am start -n app.so7o.webview/.MainActivity`
  unfreezes it before you connect.

## A real run, start to finish

*A record of an actual run — context, not a required path. Follow
[Quick start](#quick-start) and [Use](#use) instead; this is here for the parts that went wrong.*

This is the whole flow as it actually went on a phone that had never seen this repo — a Galaxy
Z Fold on Android 16 with Termux installed and nothing else. Output is trimmed, but the
awkward parts are kept on purpose. Nothing but Termux was installed on it, to prove the flow
stands on its own. It ran before the rename, so its transcript still reads `Pi WebView Shell` /
`com.pi.webview` and its network check still hits `pi.dev` — nothing below has been retro-edited
to match the current names.

### 0. What you need before you start (not scriptable)

| | why |
|---|---|
| Termux (F-Droid / GitHub releases — **not** the Play Store build) | everything below runs inside it |
| Developer options + **Wireless debugging** on | adb is how the APK gets installed |
| the **pairing code**, read off the screen | once per device; only a human can see it |

### 1. Get the code

```bash
gh repo clone jan5o7o/android-webview-cdp && cd android-webview-cdp
```

### 2. Pre-install checkup (writes nothing)

```bash
bash ./setup.sh --pre-install-checkup
```

On this phone it failed — correctly, and usefully:

```
== android platform jar
  FAIL  sdk/platforms/android-36/android.jar missing (27 MB platform jar, deliberately not in the repo)

== adb
  FAIL  no device connected
        On the phone: Settings → About phone → tap Build number 7× →
        Developer options → Wireless debugging → on → 'Pair device with pairing code'.

Do this next:
  1. curl -LO https://dl.google.com/android/repository/platform-36_r02.zip && unzip -j …
  2. adb pair <ip>:<pair-port>     # once per device; the code is on the Wireless debugging screen
  3. adb connect <ip>:<connect-port>   # changes every time Wireless debugging is toggled; 127.0.0.1:<port> works on-device

Not ready. Fix the items above, then re-run: bash ./setup.sh --pre-install-checkup
```

### 3. Fix 1 — the adb connection (the fiddly part)

Everything about this was harder than it should be, in ways worth knowing:

- The phone **changed networks during the session**, so its IP moved three times
  (`192.168.1.x` → `10.x.x.x` → `192.168.100.x`). The mDNS records went stale with it: the advertised
  **connect ports were refused** while a different port actually answered.
- **Pairing and connecting use different ports.** Attempting `adb pair` on the connect port
  gives `error: protocol fault (couldn't read status message)` — only the pairing port speaks
  that protocol. And a plain `adb connect` at a port that answers but is not accepting
  connections leaves an **`offline` transport** rather than a clean error, which looks like a
  broken device until you clear it (`adb kill-server`, or `adb disconnect <addr>`).
- `adb mdns services` does **not** work with Termux's `android-tools` build
  (`error: unknown host service 'mdns:services'`), so a zeroconf client is the way to find the
  live ports — including `_adb-tls-pairing._tcp`, which is what hands you the pairing port
  while the dialog is open.
- Because Termux runs *on* the phone, `127.0.0.1:<port>` reaches adbd and sidesteps the
  network churn completely.

So, in practice (the device serial and guid below are redacted):

```bash
$ python3 ~/adbdiscover.py                     # or any mDNS/zeroconf client
FOUND adb-RFCTB1XXXXXX-hNiWLk._adb-tls-pairing._tcp.local.  ['192.168.100.x', …] 37991
FOUND adb-RFCTB1XXXXXX-hNiWLk._adb-tls-connect._tcp.local.  ['192.168.100.x', …] 41373
FOUND adb-RFCTB1XXXXXX-hNiWLk (3)._adb-tls-connect…         ['192.168.100.x', …] 40855

$ adb pair 127.0.0.1:37991 460835
Successfully paired to 127.0.0.1:37991 [guid=adb-RFCTB1XXXXXX-hNiWLk]

$ adb connect 127.0.0.1:43803                  # the connect port that actually answered
connected to 127.0.0.1:43803

$ adb devices -l
127.0.0.1:43803   device product:q4qxxx model:SM_F936B device:q4q
```

### 4. Fix 2 — the platform jar: do nothing

`setup.sh` fetches it. With no jar anywhere on the device it downloaded the 27 MB archive
itself and extracted the jar — **27,768,026 bytes**, matching the documented size.

### 5. Build, install, verify

```bash
bash ./setup.sh
```

```
== install
  warn  signed differently from the installed copy (no keystore is committed) — uninstalling and reinstalling
  ok    installed (after uninstall)
  ok    notification permission granted

== launch and verify
  ok    relay answering on 127.0.0.1:9334 (no adb forward needed)
  ok    CDP round-trip: document.title = "Pi WebView Shell"
  ok    input injection: taps 0 → 1
  ok    real site: pi.dev → extensions ({"h1":"Extensions","path":"/docs/latest/extensions"})
  ok    screenshot: setup-check.png (phone-sized capture of that page)
```

The signature warning is expected on a fresh clone and handled automatically: no signing key is
committed, so `build.sh` generated one (`CN=Pi WebView`) and Android refused to update the
app installed from a different key — hence uninstall + reinstall.

Two lines there are worth explaining. **`real site: pi.dev → extensions`** is the flow
navigating to a real network site, waiting for its `<h1>`, and reading the DOM back — the
bundled page only proves the WebView works, this proves the arrangement does. **The screenshot
line is conditional**: a page whose window is not on screen reports `visibilityState: hidden`,
has no frames to capture, and is reported as skipped with the fix rather than as a failure.
That is what the first pass through this flow showed, before the app was on a display. Taking
the advice:

### 6. Off-screen, phone-sized, with pixels

```bash
$ ./display.sh overlay
display id   41 (overlay, 1080x2340/420 — created via overlay_display_devices)
task         5334 sized to 1080x2340
viewport     {"css":"411x851","dpr":2.625,"px":"1079x2234"}
pixels       YES — renders off-screen; capture at the display size, no clamping
relay        UP on 127.0.0.1:9334 (no adb forward)

$ node cdp.mjs --shot clone-shot.png
screenshot -> clone-shot.png            # 1082x2237 PNG of whatever page is loaded
```

(That capture is the one in [Screenshots](#screenshots): Hacker News at a phone viewport. The
flow returns the app to its own page afterwards, so it is not left on someone else's site.)

### What that run proves

| | |
|---|---|
| root | not needed |
| Shizuku / accessibility service / any companion app | **not needed** — nothing else was installed |
| adb after launch | not needed — the relay served CDP throughout |
| human hands | developer options, the pairing code, and later the display toggle |
| wall-clock cost | dominated by the 27 MB jar download and the build; the pairing was the only fiddly part |

## Files

| File | Role |
|---|---|
| `java/app/so7o/webview/MainActivity.java` | debug flag, WebView, `so7o` JS bridge (`ping`/`info`/`toast`) |
| `java/app/so7o/webview/KeepAliveService.java` | foreground service — keeps the process out of the frozen cgroup |
| `java/app/so7o/webview/RelayServer.java` | publishes the socket on `127.0.0.1:9334` (no adb needed) |
| `assets/index.html` | demo page; exposes `window.__so7o` as a stable CDP handle |
| `build.sh` | on-device build: aapt2 → javac → d8 → alignment check → apksigner |
| `cdp-webview.sh` | pid discovery, freeze handling, `adb forward`, verification |
| `cdp.mjs` | dependency-free CDP client/CLI (Node 22+ global `WebSocket`) |
| `display.sh` | put the shell on a simulated phone-sized display, off-screen |

`keystore.jks` is a throwaway dev key: `build.sh` generates it on first build, and it is never
committed.

## Running it off the phone screen (and testing at phone sizes)

One backend, and it needs nothing but adb:

```bash
./display.sh overlay                # adb only — a phone-sized simulated display
./display.sh overlay 412x915@420    # any size you like
./display.sh overlay-off            # clear it, app back to the phone

./display.sh status                 # what exists, where the app is, is the relay up
```

`settings put global overlay_display_devices "1080x2340/420"` asks system_server to create a
simulated secondary display; shell holds `WRITE_SECURE_SETTINGS`, so adb can do it — no root,
no Shizuku, no accessibility service, no other app. Result: a **phone-sized display the WebView
fills at 411×851 CSS px / dpr 2.625**, rendering off-screen. Screenshots come back at the
display's own resolution (1082×2237) with no emulation and no clamping.

Measured on SM-F936B / Android 16:

| | |
|---|---|
| JS / DOM / network / timers | yes |
| CDP input injection (`--click`, `--type`) | yes |
| the relay (no adb after launch) | yes |
| `document.visibilityState` | `visible` |
| `requestAnimationFrame` | runs |
| `Page.captureScreenshot` | works, at the display's own size |
| phone-sized natively | yes (1080×2340 as configured) |

### What a screenshot actually requires

One requirement, and nothing else matters: **the WebView's window must be on a display that is
ON and has a surface.** A capture is just "hand me the last composited frame" — no surface, no
frame, no screenshot. Read the dependencies that way:

| capability | needs | does *not* need |
|---|---|---|
| app installed and running | **adb** (`install`, `am start`) | — |
| a second display at all | **adb only** — the `overlay_display_devices` setting (shell holds `WRITE_SECURE_SETTINGS`) | root, Shizuku, accessibility service, a companion app, a physical second screen |
| screenshotting it over CDP | the above, plus a display that renders (surface + ON), plus a window that actually fills it | CDP emulation — `--device` is optional, the display is phone-sized by construction |
| reaching CDP to take one | the relay on `127.0.0.1:9334` | any adb forward |

So the minimum is three commands, and only the first two need adb:

```bash
adb install -r out/so7o-webview.apk
./display.sh overlay              # settings put + force-stop + am start --display + task resize
node cdp.mjs --shot shot.png      # 1082×2237, over the relay, zero adb
```

**No surface means no pixels.** A display created without a render target — a "headless" virtual
display, `state=OFF` — hosts and runs the app, but there is nothing to composite into, so every
capture route fails. Measured, all four:

| route | result |
|---|---|
| `Page.captureScreenshot` | times out |
| `Page.captureScreenshot` `fromSurface:false` | times out |
| `Page.captureScreenshot` `captureBeyondViewport:true` | times out |
| `Page.startScreencast` | 0 frames in 3 s |

The page there also reports `visibilityState: "hidden"` and `requestAnimationFrame` never fires —
though JS, DOM, network, **timers** and **CDP input injection** all still work, because CDP input
is injected browser-side rather than as Android input. That makes a surface-less display good for
logic/DOM/network assertions and useless for anything visual. `overlay_display_devices` has no
"don't render" option, so the adb-only path documented here always has a surface.

The same rule bites more subtly: **a `hidden` page has no frames either.** That happens when the
window stops rendering — screen off, or the activity stopped — even though the display exists.
`setup.sh` reports it as *skipped, here's the fix* rather than as a failure, for exactly this
reason. If you need pixels, `./display.sh overlay` is the answer to that warning.

### On devices without DeX

Nothing in the mechanism is DeX-specific: the simulated display is AOSP, and shell can write that
setting on any Android 14+ device. What varies between devices is **window management on
secondary displays** — which is the only reason `display.sh` force-stops and resizes.

Every measurement in this README is from an SM-F936B, which ships freeform window management, so a
task can land in a small window and keep its bounds when it moves between displays. That is what
the force-stop and the unconditional `am task resize` exist to handle.

| | freeform-capable (measured here) | typical non-DeX phone (**inferred**) |
|---|---|---|
| simulated display | works | works — same AOSP mechanism |
| window on it | may arrive small/freeform | should arrive fullscreen — no freeform to land in |
| `am task resize` | sometimes needed | usually a no-op: freeform is disabled, the call fails and is ignored (`\|\| true`) |
| screenshots | 1082×2237 verified | expected identical — surface + ON is the whole requirement |
| the phone's own screen | fullscreen (measured) | fullscreen |

If a device does not fill the display, the knob is an explicit fullscreen launch:

```bash
adb shell am start --display <id> --windowingMode 1 -f 0x10000000 -n app.so7o.webview/.MainActivity
```

and if it refuses the simulated display entirely, falling back to its own screen keeps everything
except the off-screen property. **The non-DeX column has not been run on a non-DeX phone** — it is
reasoning from the mechanism plus the flags checked on this one.

### Two traps in the adb backend, both found the hard way

- **`settings put global overlay_display_devices ""` fails** with `Bad arguments`.
  Clear it with `settings delete global overlay_display_devices` — which is what
  `overlay-off` runs. The setting is persisted, so the display comes back after a reboot
  until you delete it.
- **Stop the app before launching it onto the display.** `am start --display N` on an
  already-running activity *moves* the task: it keeps the old window size and carries the
  previous display's density, so you silently get 480×993 CSS at dpr 2.25 instead of
  411×851 at 2.625. `display.sh overlay` force-stops first, then resizes the task only if
  the window still did not come up full-width.

Also worth knowing: `screencap -a` does **not** see simulated displays (it lists only the
physical ones — 904×2316 cover and 1812×2176 inner here), so `Page.captureScreenshot`
remains the way to look at the page.

### Phone-sized viewports

Two ways, and they compose:

**1. Size the display itself.** With the adb backend the display *is* whatever you ask for,
so make it a phone. The default `./display.sh overlay` gives 1080×2340/420 → the shell fills
it at **411×851 CSS px, dpr 2.625**, and a screenshot comes back at the display's own
resolution. To host a *specific* device's full pixel grid, size the display to fit:

```bash
./display.sh overlay 1200x2700@420
node cdp.mjs --device iphone-14 --nav https://example.com --wait h1 --shot shot.png
# -> 1170x2532, unclamped (example in docs/img/example-com-iphone-14.png)
```

**2. Or emulate a device with CDP** — independent of the physical display:

```bash
node cdp.mjs --list-devices
device: pixel-7 -> {"w":412,"h":915,"dpr":2.624999910593033}
node cdp.mjs --device pixel-7 --nav https://example.com --wait h1 --shot shot.png
node cdp.mjs --metrics 412x915x2.625 …     # custom; --reset-device to clear
```

The page then sees an exact phone viewport (touch enabled, mobile UA) whatever the display is.

**The trap, caught by looking at the output instead of trusting the file size:** the WebView
composites into its window's surface, so the emulated *device-pixel* size must fit inside
that surface. Past it, `Page.captureScreenshot` still returns an image of the requested size
— with **the page drawn twice**. `cdp.mjs` clamps the scale factor to the largest standard
value (3, 2.625, 2, 1.5, 1) that fits and says so on stderr; `--no-clamp` reproduces the
tiling deliberately.

That is exactly why (1) matters: on the default 1080×2340 display a 1170×2532 viewport does
not fit, so iPhone-14 gets clamped to 2x (780×1688). Sizing the display to 1200×2700 lets the
full 3x viewport through at native resolution.

Captures are always `Page.captureScreenshot`, never `screencap`: simulated displays are not
in `screencap`'s list (it only sees the physical ones — 904×2316 cover, 1812×2176 inner).

## Stopping it — and what lingers

Measured, unusual, and worth knowing before you wonder why something is still running:

```bash
./display.sh overlay-off                  # delete the persisted setting, app back to the phone
./cdp-webview.sh down                     # remove the 9333 adb forward, if you used that path
adb shell am force-stop app.so7o.webview    # only this stops the app itself
```

- **Closing the display does not stop the app.** Destroy the display and the Activity goes
  with it, but `KeepAliveService` (the foreground service that makes the process
  freeze-exempt) outlives it — so the "So7o Android Webview Shell" notification stays up and the relay
  keeps listening on `127.0.0.1:9334`. That is by design, not a leak; it is what lets you
  drive the shell while it is not the visible app. `status` will show a live `relay UP` with
  `app display` empty — that combination is expected.
- **Only `force-stop` is a real stop**: it takes the process, the notification and the
  listening port with it.
- **An idle relay is not exposed**: the port binds `127.0.0.1` only, so nothing off-device
  can reach it (other apps on the phone could — see the gotchas).
- **The `overlay_display_devices` setting is persisted.** `overlay-off` deletes it; until then
  the simulated display is recreated after a reboot.
- The relay port is released when the process dies. Nothing else on the device is modified by
  any of this — that setting is the only one touched.

## The freeze problem (the thing that actually bites)

An Android app that is not the visible app gets **frozen** — its whole cgroup is
suspended. The process stays alive, and `/proc/net/unix` still lists the DevTools
socket, but the socket is never accepted again: clients hang instead of failing
cleanly. Measured here while the shell ran as a plain background app:

```
/proc/14178/cgroup → 5:freezer:/frozen
curl 127.0.0.1:9333/json/version → 000   (process alive, Forward in place)
```

`KeepAliveService` (a `specialUse` foreground service started in `onCreate`) makes
the process freeze-exempt. With it running:

- after **4 minutes** in the background: `cgroup unfrozen`, HTTP 200, CDP evaluating;
- `adb shell am freeze app.so7o.webview` was requested explicitly — the app kept
  answering CDP (`isFrozen` never became true).

`./cdp-webview.sh up` also calls `am start` unconditionally, which both launches a
dead app and unfreezes one the platform already parked.

## Two ways to get a port

| Path | Port | Status |
|---|---|---|
| `adb forward tcp:9333 localabstract:webview_devtools_remote_<pid>` | 9333 | verified — needs adb; re-run `up` after every app restart |
| `RelayServer` inside the app (byte-pumps its own socket to loopback) | 9334 | **verified** — no adb at all |

They cannot share a port: both bind the device's *same* loopback. The relay has to
live inside the WebView's process, because SELinux lets a process connect to an
abstract socket it created itself but not to one owned by another app — which is
exactly why an external process cannot do this job.

With the relay, `adb forward --list` is empty and CDP still answers:

```
./cdp-webview.sh direct
relay UP on 127.0.0.1:9334 (no adb forward involved)
  app.so7o.webview — Chrome/153.0.8010.36
then: node cdp.mjs --list
```

So once the app is running, **control needs no adb at all** — wireless debugging
can be off entirely. The relay is bound per *process*, so an Activity recreation
(display move, rotation) does not disturb it; a second `onCreate` logs
`relay already running` instead of a failed re-bind.

## Verified

> **Status after the rename.** Everything below has been re-run against `app.so7o.webview`:
> `/json/version` reports the new package, `Runtime.evaluate` round-trips, `so7o.ping()` answers
> `pong from app pid 1832`, `so7o.info()` returns that pid and `127.0.0.1:9334`, a click moves
> the page's own counter (`0 → 1`), the Hacker News assertion passes
> (`{"title":"Hacker News","stories":30}`), and `--shot` writes 840×1326 at the window size and
> 1082×2237 on a simulated display. `./display.sh overlay` reports `task 5599 sized to 1080x2340`
> with an `411x851` viewport, and `setup.sh` runs green end to end. All of it over the in-app
> relay; the multi-display rows are the only ones that use adb.

- Socket name is exactly `webview_devtools_remote_<pid>`, matching the app's own
  `Log.i` line and the name the Java side reports back through CDP.
- `/json/version` → `Android-Package: app.so7o.webview`, `Browser: Chrome/153`,
  UA marked `; wv`; `/json/list` → the page target.
- `Runtime.evaluate` round-trips; `Page.captureScreenshot` renders the page.
- **Input works without a finger**: `Input.dispatchMouseEvent` clicks a button and
  the page's own tap counter increments; `Input.insertText` fills a focused field;
  `Input.dispatchKeyEvent` sends keys.
- `Page.navigate` reaches external sites (the shell has `INTERNET`) and back to the
  bundled asset page.
- `Network.enable` produces `Network.requestWillBeSent`; `DOM`, `CSS`, `Network.getCookies`
  respond.
- **CDP → Java**: `so7o.info()` returns `{"pid":17493,"socket":"webview_devtools_remote_17493"}`,
  matching `adb shell pidof app.so7o.webview` exactly. The bridge really crosses processes.
- A page left alone with no interaction stays at 0 taps — input only moves when
  something injects or taps it.
- **Relay works with no adb**: `adb forward --list` empty, CDP answering on
  `127.0.0.1:9334`.
- **Capture depends on a surface, and nothing else.** On a surface-less (`state=OFF`) display
  every route fails — `captureScreenshot` (default, `fromSurface:false`,
  `captureBeyondViewport:true`) times out and `startScreencast` yields 0 frames — while JS, DOM,
  network, timers and input injection all still work. On the `overlay_display_devices` display,
  with the same app and the same commands, capture works at 1082×2237.
- **Multi-display**: launched on display **17** (XREAL One, 1920×1080, density 213)
  and display **24** (a virtual display, 1245×1397, density 360 → dpr 2.25). On each,
  CDP read the viewport and `Input.dispatchMouseEvent` clicked the button.
  `Page.captureScreenshot` gave 1247×1398 on display 24 — the page really renders at
  the target display's resolution.
- **Puppeteer drives it too**, over the relay and with no app changes: `puppeteer-core`
  `connect` → `pages()` → `goto` → DOM reads → a real click → `goBack`, all against
  `news.ycombinator.com/news` (30 stories read; story #1 clicked through to arxiv).
  `so7o.info()` crossed into Java down the same session, and `emulate()` + `screenshot()`
  captured the page at `412x915 @1.5`. `newPage()` fails with
  `Target.createTarget: Not supported`.

## Security

**There is no authentication, and WebView debugging is on unconditionally.** `MainActivity`
calls `WebView.setWebContentsDebuggingEnabled(true)` with no debug-flag guard — that is the whole
point of the project, so it will not be "fixed". The consequences are worth stating plainly:

- **Anything that can reach the port can fully drive the page** — read and mutate the DOM, run
  arbitrary JS, read cookies and `localStorage`, navigate, and call whatever the page's Java
  bridge exposes.
- **The Java bridge runs Java in the app's process.** Today `so7o.*` is `ping`/`info`/`toast`,
  which is harmless. Anything added later (file access, intents, clipboard) inherits exactly the
  same openness. Keep the bridge small, and never put a secret behind it.
- **The exposure is the device, not the network.** Both the in-app relay and `adb forward` bind
  `127.0.0.1` only (verified in `/proc/net/tcp`), so nothing is reachable over the LAN.
- **On the device, that means every app holding `INTERNET`.** There is no token, no origin check
  and no per-client allowlist — any app that can open a loopback socket can drive the shell and
  read the result. Treat a running instance as open to every other app on the phone.
- **Don't leave it running on a device you care about.** `adb shell am force-stop
  app.so7o.webview` stops everything — process, notification and port. `./cdp-webview.sh down`
  only removes the adb forward; it does not stop the app.

## Gotchas

- **Assets are a build change**: `aapt2 link` needs `-A <dir>`, or your HTML silently
  isn't in the APK.
- **The forward dies with the process** (new pid ⇒ re-run `up`), and
  `adb forward tcp:9333 …` silently *replaces* an existing forward on that port.
  `adb forward --list` shows what's wired; 9222/9223 are Chrome's.
- **`Runtime.enable` replays buffered `console.*`** from before the connection.
  `cdp.mjs` suppresses the replay; `DEBUG=1` shows everything.
- **The devtools server accumulates page targets.** Every WebView ever created in
  the process stays listed, so after a few Activity recreations `/json/list` shows
  several identical targets. Picking "the first page" then reads one page and clicks
  another (this bit me: a single click read back as `0 → 3`). `cdp.mjs` probes each
  target and uses the one reporting `visibilityState === 'visible'`; pin one with
  `--target <id>`.
- **`screencap -d N` does not take the Android display id** — it takes the
  SurfaceFlinger token from `dumpsys SurfaceFlinger --display-id` (and defaults to
  the *cover* screen otherwise). It also refuses the virtual display's token as
  "not valid", and `-a` only enumerates active *physical* displays. To see a WebView
  on an unusual display, capture through CDP (`--shot`) instead.
- **No surface, or a `hidden` page, means no pixels.** A display without a render target, or a
  window that has stopped rendering, produces no frames — every capture route times out. See
  *What a screenshot actually requires*.
- **A backgrounded app cannot show a Toast** (Android 11+). `so7o.toast()` still
  executes Java, but nothing appears unless the app is foreground or holds
  `SYSTEM_ALERT_WINDOW`.
- **`Target.createTarget` / `/json/new` are blocked on Android** — attach to an
  existing page target, don't try to create one (same restriction as Chrome).
- The forward binds **127.0.0.1 only** (verified in `/proc/net/tcp`), so it is not
  on the LAN — but any app on the phone holding `INTERNET` could drive the page.
  `./cdp-webview.sh down` when done.

## Not done yet (deliberately)

- No overlay/floating variant — this is an Activity. A `TYPE_ACCESSIBILITY_OVERLAY`
  WebView would need a display context for DeX, and care with the click-through trick.
- Multiple simultaneous CDP *clients* on one target are untested (multiple targets
  definitely coexist; that is a different question).

## Environment notes

- The `overlay_display_devices` backend is a **persisted global setting**: it survives a
  reboot until you clear it with `./display.sh overlay-off`.

## Working on this repo

**`dev` is the default and integration branch; `main` is releases only.** `main` is protected —
PR required, linear history, no force-push — so nothing lands there except a `dev` → `main` pull
request. Branch off `dev`, PR back into it, and cut a release by tagging `vX.Y.Z` on `main` with
the signed APK attached.

[`AGENTS.md`](AGENTS.md) carries the fuller version, including a cold-start checklist for the adb
connection — the pairing step is the only part that needs a human, and it behaves slightly
differently every time.

CI runs on pushes and pull requests: shell syntax, ShellCheck, `node --check`, XML
well-formedness, and two consistency checks — that everything hardcoding the package agrees with
`AndroidManifest.xml` (including the absence of a stale *escaped* pattern, which is a bug that sat
in `display.sh` reporting "is the app installed?" while the app was running), and that the bundled
page's `<title>` is the string `setup.sh` asserts. **The APK build is not gated**: it needs Android
build-tools plus the 27 MB platform jar and is shaped for Termux, so a green tick means the scripts
parse, lint and agree — not that the app builds.

## License

MIT — see [LICENSE](LICENSE). (Matches the license Pi itself is published under.)
