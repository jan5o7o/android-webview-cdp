#!/data/data/com.termux/files/usr/bin/bash
# Put so7o-android-webview-shell on a secondary display, off the phone screen.
#
#   ./display.sh overlay [WxH@DPI]   create a simulated secondary display (adb only),
#                                    launch the shell there, size it to fill it
#   ./display.sh overlay-off         clear the setting, app back to the phone screen
#   ./display.sh status              what exists right now
#
# How it works: `settings put global overlay_display_devices "1080x2340/420"` asks
# system_server to create a simulated secondary display. Shell holds
# WRITE_SECURE_SETTINGS, so adb alone can do it — no root, no accessibility service,
# no companion app. The display is phone-sized natively: the WebView fills it at
# 411x851 CSS px / dpr 2.625 and renders off-screen, so screenshots come back at the
# display's own resolution (1082x2237) with no emulation and no clamping.
#
# Measured, not assumed: rendering works (visibilityState=visible, rAF runs), CDP input
# injection works, and the relay keeps serving with no adb forward.
#
# Four things that bite — all found the hard way:
#   * `settings put global overlay_display_devices ""` fails with "Bad arguments";
#     clear it with `settings delete` (what overlay-off does)
#   * the setting wants WxH/DPI, not WxH@DPI (either is accepted here, normalised)
#   * `am start --display N` on a running activity MOVES the task, keeping the old
#     window size and carrying the previous display's density with it — so stop the
#     app first, or you silently get 480x993 CSS at dpr 2.25 instead of 411x851 at 2.625
#   * a task keeps its bounds when the display changes, so a window can arrive *larger*
#     than the new display; the task is therefore sized unconditionally
#
# The setting is persisted: the display is recreated after a reboot until you clear it.
set -euo pipefail

PKG=app.so7o.webview
ACTIVITY="$PKG/.MainActivity"
OVERLAY_SPEC="${OVERLAY_SPEC:-1080x2340/420}"
ADB="${ADB:-adb}"

display_of_app() {
    $ADB shell dumpsys activity activities 2>/dev/null \
        | awk -v pkg="$PKG" '/Display #/{d=$2} index($0, pkg "/.MainActivity"){print d; exit}'
}
relay_up() {
    [ "$(curl -s -m 4 -o /dev/null -w '%{http_code}' http://127.0.0.1:9334/json/version 2>/dev/null || true)" = "200" ]
}
relay_line() {
    if relay_up; then printf 'relay        UP on 127.0.0.1:9334 (no adb forward)\n'
    else printf 'relay        DOWN — is the app running? (./cdp-webview.sh up)\n'; fi
}
all_ids() { $ADB shell dumpsys display 2>/dev/null | grep -oE 'mDisplayId=[0-9]+' | cut -d= -f2 | sort -un | tr '\n' ' '; }
task_on_display() {
    # index() rather than a regex: the package name needs no escaping this way, and a
    # stale pattern here silently reports "is the app installed?" while it is running.
    $ADB shell dumpsys activity activities 2>/dev/null | awk -v want="#$1" -v pkg="$PKG" '
        /Display #/ { cur = $2 }
        cur == want && index($0, pkg "/.MainActivity") {
            if (match($0, /t[0-9]+/)) { print substr($0, RSTART + 1, RLENGTH - 1); exit }
        }'
}

overlay() {
    local spec="${1:-$OVERLAY_SPEC}"
    # Accept WxH@DPI or WxH/DPI. The *setting* only understands the slash form
    # (AOSP's OverlayDisplayAdapter parser), so normalise it.
    local w h dpi setting
    w="${spec%%x*}"
    local rest="${spec#*x}"
    h="${rest%%[ @/]*}"
    dpi="$(printf '%s' "$rest" | sed -n 's/^[0-9]*[ @/]\([0-9][0-9]*\)$/\1/p')"
    [ -n "$dpi" ] || dpi=420
    case "$w" in ''|*[!0-9]*) echo "bad size '$spec' — want WxH@DPI, e.g. 1080x2340@420" >&2; exit 1;; esac
    case "$h" in ''|*[!0-9]*) echo "bad height in '$spec'" >&2; exit 1;; esac
    setting="${w}x${h}/${dpi}"
    local before after id task vp

    before="$(all_ids)"
    # `settings delete` (not `put ... ""`, which errors with "Bad arguments") is what
    # removes the display; recreating guarantees a fresh id for the diff below.
    $ADB shell settings delete global overlay_display_devices >/dev/null 2>&1 || true
    sleep 1
    $ADB shell settings put global overlay_display_devices "$setting" >/dev/null
    for _ in $(seq 1 20); do
        after="$(all_ids)"
        id=""
        for cand in $after; do
            case " $before " in *" $cand "*) ;; *) id="$cand" ;; esac
        done
        [ -n "$id" ] && break
        sleep 1
    done
    [ -n "${id:-}" ] || { echo "no new display appeared for '$setting'" >&2; exit 1; }

    printf 'display id   %s (overlay, %s)\n' "$id" "$setting"

    # Stop first, then launch on the display: *moving* an existing task onto it keeps the
    # old window size and the previous display's density.
    $ADB shell am force-stop "$PKG" >/dev/null 2>&1 || true
    sleep 1
    $ADB shell am start --display "$id" -f 0x10000000 -n "$ACTIVITY" >/dev/null 2>&1 || true
    for _ in $(seq 1 30); do
        task="$(task_on_display "$id")"
        [ -n "$task" ] && break
        sleep 0.5
    done
    # the relay is started in onCreate, so wait for it to come back after the restart
    for _ in $(seq 1 30); do relay_up && break; sleep 0.5; done

    if [ -n "${task:-}" ]; then
        # Always resize (idempotent): a task keeps its bounds when the display changes,
        # so a window can come up *larger* than the new display — not just smaller.
        $ADB shell am task resize "$task" 0 0 "$w" "$h" >/dev/null 2>&1 || true
        sleep 2
        printf 'task         %s sized to %sx%s\n' "$task" "$w" "$h"
    else
        printf 'task         not found on display %s — is the app installed?\n' "$id" >&2
    fi
    vp="$(node cdp.mjs 'JSON.stringify({css:innerWidth+"x"+innerHeight,dpr:devicePixelRatio,px:Math.round(innerWidth*devicePixelRatio)+"x"+Math.round(innerHeight*devicePixelRatio)})' 2>/dev/null | tail -1 || true)"
    printf 'viewport     %s\n' "${vp:-<not answering>}"
    printf 'pixels       YES — renders off-screen; capture at the display size, no clamping\n'
    printf 'next         node cdp.mjs --shot shot.png          (no --device needed)\n'
    printf '             node cdp.mjs --device pixel-7 …       (only to pin a specific phone)\n'
    relay_line
}

case "${1:-status}" in
  overlay)
    overlay "${2:-}"
    ;;
  overlay-off)
    $ADB shell settings delete global overlay_display_devices >/dev/null
    sleep 3
    $ADB shell am start -n "$ACTIVITY" >/dev/null 2>&1 || true
    printf 'overlay-display setting cleared; app display %s\n' "$(display_of_app)"
    ;;
  status)
    printf 'overlay set  %s\n' "$($ADB shell settings get global overlay_display_devices | tr -d '\r')"
    printf 'displays     %s\n' "$(all_ids)"
    printf 'app display  %s\n' "$(display_of_app)"
    relay_line
    ;;
  *)
    sed -n '2,10p' "$0"; exit 1
    ;;
esac
